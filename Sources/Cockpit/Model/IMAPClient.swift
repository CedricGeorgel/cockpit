import Foundation
import Network

/// Un message à trier, quelle que soit la source. Les propriétés sont
/// dérivées des en-têtes, mais peuvent être fournies explicitement (Mail.app
/// donne déjà l'objet, la date, l'état lu/signalé).
struct RawMessage {
    var uid: Int
    var flags: [String] = []
    var headers: [String: String] = [:]

    var explicitSeen: Bool?
    var explicitFlagged: Bool?
    var explicitDate: Date?
    var explicitFrom: String?
    var explicitSubject: String?
    var explicitMessageID: String?

    /// Message-ID RFC 822, sans chevrons. Sert à rouvrir le mail dans Mail.app.
    var messageID: String {
        let raw = explicitMessageID ?? headers["message-id"] ?? ""
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
    }

    var seen: Bool {
        explicitSeen ?? flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }
    }
    var flagged: Bool {
        explicitFlagged ?? flags.contains { $0.caseInsensitiveCompare("\\Flagged") == .orderedSame }
    }

    /// Newsletter / envoi en masse : présence d'un en-tête de liste.
    var isBulk: Bool {
        headers["list-unsubscribe"] != nil
            || headers["list-id"] != nil
            || (headers["precedence"]?.lowercased().contains("bulk") ?? false)
            || (headers["precedence"]?.lowercased().contains("list") ?? false)
    }

    /// Un vrai lien de désabonnement (RFC 2369/8058), pas juste un en-tête de
    /// liste — sert à proposer « se désabonner » plutôt qu'à trier l'important.
    var hasUnsubscribeLink: Bool { headers["list-unsubscribe"] != nil }

    private var fromField: String { explicitFrom ?? headers["from"] ?? "" }
    var fromAddress: String { MailParse.address(in: fromField).email }
    var fromName: String {
        let a = MailParse.address(in: fromField)
        return a.name.isEmpty ? a.email : a.name
    }
    var subject: String {
        MailParse.decodeWords(explicitSubject ?? headers["subject"] ?? "(sans objet)")
    }
    var date: Date { explicitDate ?? MailParse.date(headers["date"] ?? "") ?? .distantPast }
}

enum IMAPError: LocalizedError {
    case connection(String)
    case login(String)
    case oauthRequired
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .connection(let m): return "Connexion impossible : \(m)"
        case .oauthRequired:
            return "Ce serveur n'accepte plus le mot de passe simple (Gmail/Outlook récents exigent OAuth ou un mot de passe d'application)."
        case .login(let m):
            return m.isEmpty ? "Identifiant ou mot de passe refusé" : "Refusé : \(m)"
        case .protocolError(let m): return "Réponse inattendue du serveur (\(m))"
        }
    }
}

/// Client IMAP minimal : juste ce qu'il faut pour lister les messages récents
/// de la boîte de réception et les adresses avec qui on a déjà échangé.
/// TLS implicite (port 993). Un client par rafraîchissement, pas de connexion
/// persistante.
final class IMAPClient {
    private let conn: NWConnection
    private var inbuf = Data()
    private var tag = 0
    private let crlf = Data([13, 10])

    init(host: String, port: Int) {
        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        conn = NWConnection(host: .init(host), port: .init(rawValue: UInt16(port)) ?? 993, using: params)
    }

    typealias Result = MailFetch

    enum Auth {
        case password(String)
        case xoauth2(token: String)
    }

    func fetchImportant(user: String, auth: Auth,
                        inboxDays: Int = 12, sentDays: Int = 120) async throws -> Result {
        try await open()
        defer { conn.cancel() }

        let greeting = String(decoding: try await readLine(), as: UTF8.self)

        switch auth {
        case .password(let password):
            let caps = try await command("CAPABILITY")
            let capDisabled = (caps.lines + [greeting]).joined(separator: " ")
                .uppercased().contains("LOGINDISABLED")

            let login = try await command("LOGIN \(quoted(user)) \(quoted(password))")
            guard login.ok else {
                var detail = login.status
                if let alert = login.lines.first(where: { $0.uppercased().contains("ALERT") }) {
                    detail = alert.replacingOccurrences(of: "* OK [ALERT] ", with: "")
                                  .replacingOccurrences(of: "* NO [ALERT] ", with: "")
                }
                let d = detail.uppercased()
                if capDisabled || d.contains("OAUTH") || d.contains("WEB BROWSER")
                    || d.contains("APPLICATION-SPECIFIC") || d.contains("BASIC AUTHENTICATION") {
                    throw IMAPError.oauthRequired
                }
                throw IMAPError.login(detail.trimmingCharacters(in: .whitespaces))
            }

        case .xoauth2(let token):
            let raw = "user=\(user)\u{01}auth=Bearer \(token)\u{01}\u{01}"
            let b64 = Data(raw.utf8).base64EncodedString()
            let r = try await command("AUTHENTICATE XOAUTH2 \(b64)")
            guard r.ok else {
                throw IMAPError.login(r.status.isEmpty ? "jeton OAuth refusé" : r.status)
            }
        }

        let sentBox = try await findSentMailbox()

        // Boîte de réception.
        _ = try await command("SELECT INBOX")
        let uids = try await search(sinceDays: inboxDays)
        var messages: [RawMessage] = []
        if !uids.isEmpty {
            messages = try await fetchHeaders(
                uids: Array(uids.suffix(120)),
                fields: "FROM SUBJECT DATE MESSAGE-ID LIST-UNSUBSCRIBE LIST-ID PRECEDENCE")
        }

        // Correspondants connus : destinataires de nos messages envoyés.
        var known: Set<String> = []
        if let sentBox {
            _ = try await command("SELECT \(quoted(sentBox))")
            let sentUIDs = try await search(sinceDays: sentDays)
            if !sentUIDs.isEmpty {
                let sent = try await fetchHeaders(uids: Array(sentUIDs.suffix(250)), fields: "TO CC")
                for m in sent {
                    for field in ["to", "cc"] {
                        for addr in MailParse.addresses(in: m.headers[field] ?? "") {
                            if !addr.email.isEmpty { known.insert(addr.email.lowercased()) }
                        }
                    }
                }
            }
        }

        _ = try? await command("LOGOUT")
        return Result(messages: messages, knownCorrespondents: known)
    }

    // MARK: Étapes

    private func findSentMailbox() async throws -> String? {
        let r = try await command("LIST \"\" \"*\"")
        var fallback: String?
        for line in r.lines where line.hasPrefix("* LIST") {
            let lower = line.lowercased()
            // Nom entre guillemets en fin de ligne.
            guard let name = line.range(of: "\"", options: .backwards).flatMap({ end -> String? in
                let before = line[..<end.lowerBound]
                guard let start = before.range(of: "\"", options: .backwards) else { return nil }
                return String(line[start.upperBound..<end.lowerBound])
            }) else { continue }
            if lower.contains("\\sent") { return name }
            let leaf = name.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init)?.lowercased() ?? name.lowercased()
            if leaf == "sent" || leaf.contains("envoy") || leaf == "sent messages" || leaf == "sent mail" {
                fallback = name
            }
        }
        return fallback
    }

    private func search(sinceDays days: Int) async throws -> [Int] {
        let since = MailParse.imapDate(Date().addingTimeInterval(-Double(days) * 86_400))
        let r = try await command("UID SEARCH SINCE \(since)")
        for line in r.lines where line.uppercased().hasPrefix("* SEARCH") {
            return line.dropFirst("* SEARCH".count)
                .split(separator: " ").compactMap { Int($0) }
        }
        return []
    }

    private func fetchHeaders(uids: [Int], fields: String) async throws -> [RawMessage] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map(String.init).joined(separator: ",")
        let r = try await command("UID FETCH \(set) (UID FLAGS BODY.PEEK[HEADER.FIELDS (\(fields))])")
        return r.rawLines.compactMap { parseFetch($0) }
    }

    // MARK: Parsing FETCH

    private func parseFetch(_ data: Data) -> RawMessage? {
        // Préfixe texte (jusqu'au littéral) pour UID / FLAGS.
        let ascii = String(decoding: data, as: UTF8.self)
        guard ascii.contains("FETCH") else { return nil }
        let uid = firstInt(after: "UID ", in: ascii) ?? -1
        var flags: [String] = []
        if let fr = ascii.range(of: "FLAGS ("),
           let end = ascii[fr.upperBound...].firstIndex(of: ")") {
            flags = ascii[fr.upperBound..<end].split(separator: " ").map(String.init)
        }

        var headers: [String: String] = [:]
        if let braceOpen = data.firstRange(of: Data("{".utf8)),
           let braceClose = data.range(of: Data("}".utf8), in: braceOpen.upperBound..<data.count),
           let n = Int(String(decoding: data[braceOpen.upperBound..<braceClose.lowerBound], as: UTF8.self)),
           let crlfRange = data.range(of: crlf, in: braceClose.upperBound..<data.count) {
            let start = crlfRange.upperBound
            let block = data.subdata(in: start..<min(start + n, data.count))
            headers = MailParse.headerFields(String(decoding: block, as: UTF8.self))
        }
        guard uid >= 0 else { return nil }
        return RawMessage(uid: uid, flags: flags, headers: headers)
    }

    private func firstInt(after prefix: String, in s: String) -> Int? {
        guard let r = s.range(of: prefix) else { return nil }
        let digits = s[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: Transport

    private func open() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume()
                case .failed(let e): cont.resume(throwing: IMAPError.connection(e.localizedDescription))
                case .waiting(let e): cont.resume(throwing: IMAPError.connection(e.localizedDescription))
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
        conn.stateUpdateHandler = nil
    }

    private struct Response { var ok: Bool; var status: String; var lines: [String]; var rawLines: [Data] }

    private func command(_ cmd: String) async throws -> Response {
        tag += 1
        let t = "a\(tag)"
        try await write(Data("\(t) \(cmd)\r\n".utf8))
        var lines: [String] = []
        var raw: [Data] = []
        while true {
            let lineData = try await readLine()
            let line = String(decoding: lineData, as: UTF8.self)
            // Demande de continuation SASL (ex. échec XOAUTH2) : on répond par
            // une ligne vide pour laisser le serveur conclure.
            if line.hasPrefix("+") {
                try await write(crlf)
                continue
            }
            if line.hasPrefix("\(t) ") {
                let rest = String(line.dropFirst(t.count + 1))
                let ok = rest.uppercased().hasPrefix("OK")
                var status = rest
                for kw in ["OK ", "NO ", "BAD "] where status.uppercased().hasPrefix(kw) {
                    status = String(status.dropFirst(kw.count))
                }
                return Response(ok: ok, status: status.trimmingCharacters(in: .whitespaces),
                                lines: lines, rawLines: raw)
            }
            lines.append(line)
            raw.append(lineData)
        }
    }

    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: IMAPError.connection(err.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    /// Une « ligne » logique IMAP : jusqu'au CRLF, mais un `{n}` en fin de
    /// segment introduit n octets littéraux (qui peuvent contenir des CRLF).
    private func readLine() async throws -> Data {
        var searchFrom = 0
        while true {
            if let range = inbuf.range(of: crlf, in: searchFrom..<inbuf.count) {
                let lineEnd = range.lowerBound
                let afterCRLF = range.upperBound
                if let n = literalLength(upTo: lineEnd) {
                    while inbuf.count < afterCRLF + n {
                        inbuf.append(try await receiveChunk())
                    }
                    searchFrom = afterCRLF + n
                    continue
                }
                let line = inbuf.subdata(in: 0..<lineEnd)
                inbuf.removeSubrange(0..<afterCRLF)
                return line
            }
            inbuf.append(try await receiveChunk())
        }
    }

    private func literalLength(upTo end: Int) -> Int? {
        guard end >= 3, inbuf[end - 1] == UInt8(ascii: "}") else { return nil }
        var i = end - 2
        var digits: [UInt8] = []
        while i >= 0, inbuf[i] >= UInt8(ascii: "0"), inbuf[i] <= UInt8(ascii: "9") {
            digits.insert(inbuf[i], at: 0); i -= 1
        }
        guard i >= 0, inbuf[i] == UInt8(ascii: "{"), !digits.isEmpty else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, err in
                if let err { cont.resume(throwing: IMAPError.connection(err.localizedDescription)); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(throwing: IMAPError.connection("connexion fermée")); return }
                cont.resume(returning: Data())
            }
        }
    }

    private func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

private extension Data {
    func firstRange(of needle: Data) -> Range<Int>? { range(of: needle) }
}
