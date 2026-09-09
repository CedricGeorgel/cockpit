import Foundation
import AppKit

/// Lecture des boîtes déjà configurées dans Mail.app, via AppleScript.
/// Aucun identifiant à saisir : macOS a déjà fait l'authentification (mot de
/// passe, OAuth Gmail/Outlook…). Il faut juste l'autorisation « Automatisation ».
enum AppleMailBridge {

    static var isMailInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") != nil
    }

    enum BridgeError: LocalizedError {
        case notAuthorized
        case script(String)
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Cockpit n'est pas autorisé à lire Mail (Réglages Système › Confidentialité › Automatisation)."
            case .script(let m):  return m
            }
        }
    }

    // MARK: Comptes

    static func accountNames() throws -> [String] {
        // Mail peut être en cours de démarrage : on lui laisse le temps de
        // charger ses comptes avant de renoncer.
        let out = try run("""
        tell application "Mail"
            if it is not running then
                launch
                delay 1
            end if
            repeat 12 times
                if (count of (every account whose enabled is true)) > 0 then exit repeat
                delay 0.5
            end repeat
            return name of every account whose enabled is true
        end tell
        """)
        return parseList(out).filter { !$0.isEmpty }
    }

    // MARK: Relève

    static func fetch(account: String, days: Int = 10, sentDays: Int = 120) throws -> MailFetch {
        let cutoff = "(current date) - (\(days) * days)"
        // Deux ensembles : les messages récents, et TOUS les messages marqués
        // (sans limite de date, on flague pour garder sous la main).
        let raw = try run("""
        set output to ""
        tell application "Mail"
            set acc to first account whose name is "\(esc(account))"
            set box to missing value
            try
                set box to mailbox "INBOX" of acc
            end try
            if box is missing value then
                repeat with aBox in mailboxes of acc
                    set bn to (name of aBox as string)
                    if bn is "INBOX" or bn is "Inbox" or bn contains "réception" or bn contains "Reception" or bn contains "Posteingang" then
                        set box to aBox
                        exit repeat
                    end if
                end repeat
            end if
            if box is missing value then return "«ERR»pas de boîte de réception"
            set recentMsgs to (messages of box whose date received > \(cutoff))
            set flaggedMsgs to {}
            repeat with aBox in mailboxes of acc
                set bn to (name of aBox as string)
                if bn does not contain "supprim" and bn does not contain "Deleted" and bn does not contain "indésirable" and bn does not contain "Junk" and bn does not contain "Spam" and bn does not contain "envoi" and bn does not contain "Sent" and bn does not contain "envoyés" and bn does not contain "rouillon" and bn does not contain "Draft" then
                    try
                        set flaggedMsgs to flaggedMsgs & (messages of aBox whose flagged status is true)
                    end try
                end if
            end repeat
            repeat with aMsg in (recentMsgs & flaggedMsgs)
                set theSubject to ""
                try
                    set theSubject to subject of aMsg
                end try
                set theSender to sender of aMsg
                set theDate to (date received of aMsg) as string
                set wasRead to (aMsg's read status) as string
                set wasFlagged to (aMsg's flagged status) as string
                set theID to ""
                try
                    set theID to (message id of aMsg) as string
                end try
                set theHeaders to ""
                try
                    set theHeaders to all headers of aMsg
                end try
                set output to output & theID & "«F»" & theSubject & "«F»" & theSender & "«F»" & theDate & "«F»" & wasRead & "«F»" & wasFlagged & "«F»" & theHeaders & "«R»"
            end repeat
        end tell
        return output
        """)
        if raw.hasPrefix("«ERR»") { throw BridgeError.script(String(raw.dropFirst(5))) }

        var messages: [RawMessage] = []
        var seenIDs = Set<String>()
        for rec in raw.components(separatedBy: "«R»") where !rec.isEmpty {
            // [id, subject, sender, date, read, flagged, headers]
            let f = rec.components(separatedBy: "«F»")
            guard f.count >= 6 else { continue }
            let id = f[0].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty {
                if seenIDs.contains(id) { continue }
                seenIDs.insert(id)
            }
            var headers: [String: String] = [:]
            if f.count >= 7 {
                let h = MailParse.headerFields(f[6])
                for key in ["list-unsubscribe", "list-id", "precedence"] {
                    if let v = h[key] { headers[key] = v }
                }
            }
            messages.append(RawMessage(
                uid: messages.count,
                headers: headers,
                explicitSeen: f[4].trimmingCharacters(in: .whitespaces) == "true",
                explicitFlagged: f[5].trimmingCharacters(in: .whitespaces) == "true",
                explicitDate: appleDate(f[3]),
                explicitFrom: f[2],
                explicitSubject: f[1],
                explicitMessageID: id.isEmpty ? nil : id))
        }

        let known = (try? sentRecipients(account: account, days: sentDays)) ?? []
        return MailFetch(messages: messages, knownCorrespondents: known)
    }

    private static func sentRecipients(account: String, days: Int) throws -> Set<String> {
        let raw = try run("""
        set output to ""
        tell application "Mail"
            set acc to first account whose name is "\(esc(account))"
            set sentBox to missing value
            try
                set sentBox to sent mailbox of acc
            end try
            if sentBox is missing value then return ""
            set theCutoff to (current date) - (\(days) * days)
            set theMessages to (messages of sentBox whose date sent > theCutoff)
            repeat with aMsg in theMessages
                repeat with aRecipient in to recipients of aMsg
                    set output to output & (address of aRecipient) & "«R»"
                end repeat
            end repeat
        end tell
        return output
        """)
        return Set(raw.components(separatedBy: "«R»")
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") })
    }

    // MARK: AppleScript

    private static func run(_ source: String) throws -> String {
        do {
            return try OSAScript.run(source)
        } catch OSAScript.Failure.notAuthorized {
            throw BridgeError.notAuthorized
        } catch OSAScript.Failure.other(let m) {
            throw BridgeError.script(m)
        }
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func parseList(_ s: String) -> [String] {
        s.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static let appleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        return f
    }()

    static func appleDate(_ s: String) -> Date {
        // « samedi 6 septembre 2025 à 14:32:10 », on retombe sur le parseur RFC
        // si le format système ne colle pas.
        let cleaned = s.trimmingCharacters(in: .whitespaces)
        for fmt in ["EEEE d MMMM yyyy 'à' HH:mm:ss", "d MMMM yyyy 'à' HH:mm:ss",
                    "EEEE, MMMM d, yyyy 'at' h:mm:ss a", "dd/MM/yyyy HH:mm:ss"] {
            appleDateFormatter.dateFormat = fmt
            if let d = appleDateFormatter.date(from: cleaned) { return d }
        }
        return MailParse.date(cleaned) ?? Date()
    }
}
