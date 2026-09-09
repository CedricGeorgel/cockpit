import Foundation

/// Résultat d'une relève, quelle que soit la source (IMAP direct ou Mail.app).
struct MailFetch {
    var messages: [RawMessage]
    var knownCorrespondents: Set<String>
}

/// Analyse de bas niveau des en-têtes RFC 822 : dépliage, mots encodés MIME,
/// adresses, dates.
enum MailParse {

    /// Découpe un bloc d'en-têtes en dictionnaire (clé en minuscules).
    /// Les lignes de continuation (commençant par une espace) sont recollées.
    static func headerFields(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var currentKey: String?
        var currentVal = ""

        func flush() {
            if let k = currentKey {
                out[k, default: ""] += (out[k] == nil ? "" : " ") + currentVal.trimmingCharacters(in: .whitespaces)
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.first == " " || line.first == "\t" {
                currentVal += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                flush()
                currentKey = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                currentVal = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return out
    }

    struct Address { var name: String; var email: String }

    static func address(in field: String) -> Address {
        addresses(in: field).first ?? Address(name: "", email: "")
    }

    static func addresses(in field: String) -> [Address] {
        guard !field.isEmpty else { return [] }
        // Découpe sur les virgules hors guillemets.
        var parts: [String] = []
        var buf = ""
        var inQuote = false
        for ch in field {
            if ch == "\"" { inQuote.toggle(); buf.append(ch) }
            else if ch == "," && !inQuote { parts.append(buf); buf = "" }
            else { buf.append(ch) }
        }
        if !buf.isEmpty { parts.append(buf) }

        return parts.compactMap { raw in
            let piece = raw.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { return nil }
            if let open = piece.range(of: "<"), let close = piece.range(of: ">", range: open.upperBound..<piece.endIndex) {
                let email = String(piece[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
                var name = String(piece[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return Address(name: decodeWords(name), email: email)
            }
            return Address(name: "", email: piece)
        }
    }

    /// Décode les mots encodés MIME : =?charset?B?...?= et =?charset?Q?...?=
    static func decodeWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var result = ""
        var rest = Substring(input)
        while let start = rest.range(of: "=?") {
            result += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let q1 = after.range(of: "?"),
                  let q2 = after.range(of: "?", range: q1.upperBound..<after.endIndex),
                  let end = after.range(of: "?=", range: q2.upperBound..<after.endIndex) else {
                result += "=?"; rest = after; continue
            }
            let charset = String(after[..<q1.lowerBound])
            let enc = after[q1.upperBound..<q2.lowerBound].uppercased()
            let payload = String(after[q2.upperBound..<end.lowerBound])
            let encoding = charsetEncoding(charset)
            var decoded: String?
            if enc == "B" {
                if let d = Data(base64Encoded: payload.padding(toLength: ((payload.count + 3) / 4) * 4, withPad: "=", startingAt: 0)) {
                    decoded = String(data: d, encoding: encoding)
                }
            } else if enc == "Q" {
                decoded = decodeQ(payload, encoding: encoding)
            }
            result += decoded ?? payload
            rest = after[end.upperBound...]
            // Un espace entre deux mots encodés adjacents doit être supprimé.
            if rest.first == " ", rest.dropFirst().hasPrefix("=?") { rest = rest.dropFirst() }
        }
        result += rest
        return result
    }

    private static func decodeQ(_ s: String, encoding: String.Encoding) -> String? {
        var bytes: [UInt8] = []
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "_" { bytes.append(0x20) }
            else if c == "=" {
                let h1 = it.next(); let h2 = it.next()
                if let h1, let h2, let b = UInt8("\(h1)\(h2)", radix: 16) { bytes.append(b) }
            } else {
                bytes.append(contentsOf: Array(String(c).utf8))
            }
        }
        return String(data: Data(bytes), encoding: encoding)
    }

    private static func charsetEncoding(_ name: String) -> String.Encoding {
        switch name.lowercased() {
        case "utf-8", "utf8":                return .utf8
        case "iso-8859-1", "latin1":        return .isoLatin1
        case "iso-8859-15":                 return .isoLatin2
        case "windows-1252", "cp1252":      return .windowsCP1252
        case "us-ascii", "ascii":           return .ascii
        default:                            return .utf8
        }
    }

    // MARK: Dates

    static func imapDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd-MMM-yyyy"
        return f.string(from: date)
    }

    private static let dateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z",
    ]

    static func date(_ raw: String) -> Date? {
        let cleaned = raw.replacingOccurrences(of: "  ", with: " ")
            .components(separatedBy: " (").first ?? raw
        for pattern in dateFormats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = pattern
            if let d = f.date(from: cleaned.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }
}
