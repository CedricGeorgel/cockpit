import Foundation

/// Exécute un AppleScript via `/usr/bin/osascript`.
///
/// `NSAppleScript` exige le thread principal : appelé depuis une file de fond
/// il renvoie silencieusement une chaîne vide. Un processus séparé n'a pas
/// cette contrainte, et l'autorisation « Automatisation » reste demandée à
/// Cockpit.
enum OSAScript {
    enum Failure: LocalizedError {
        case notAuthorized
        case other(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Autorisation « Automatisation » refusée (Réglages Système › Confidentialité)."
            case .other(let m):  return m.isEmpty ? "Erreur AppleScript" : m
            }
        }
    }

    @discardableResult
    static func run(_ source: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        var args: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            args.append("-e"); args.append(String(line))
        }
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { throw Failure.other(error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        if p.terminationStatus != 0 {
            let lower = errText.lowercased()
            if errText.contains("-1743") || lower.contains("not allowed") || lower.contains("not authori")
                || errText.contains("-600") {
                throw Failure.notAuthorized
            }
            throw Failure.other(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
