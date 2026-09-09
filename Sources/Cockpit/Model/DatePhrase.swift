import Foundation

/// Extrait une date/heure d'une phrase FR de rappel et renvoie le titre nettoyé.
///   « demain 9h appeler Paul »  → ("appeler Paul", 2026-09-10 09:00, timed)
///   « payer le loyer lundi »     → ("payer le loyer", lundi prochain, all-day)
///   « dans 2h relancer »         → ("relancer", now+2h, timed)
enum DatePhrase {

    struct Result { var title: String; var due: Date?; var timed: Bool }

    static func parse(_ raw: String, now: Date = Date(), cal: Calendar = .current) -> Result {
        var s = " " + raw.trimmingCharacters(in: .whitespaces) + " "
        let low = s.folding(options: .diacriticInsensitive, locale: nil).lowercased()

        var day: Date? = nil          // jour visé (sans heure)
        var hour: (h: Int, m: Int)? = nil
        var relative: Date? = nil     // « dans X … » (déjà daté+heuré)

        func cut(_ pattern: String) {
            if let r = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                s.replaceSubrange(r, with: " ")
            }
        }

        // --- « dans X unités » ---
        if let m = firstMatch(low, #"\bdans\s+(\d{1,3})\s*(min|minutes?|h|heures?|j|jours?|sem|semaines?)\b"#) {
            let n = Double(m[1]) ?? 0
            switch m[2].prefix(3) {
            case "min":                    relative = now.addingTimeInterval(n * 60)
            case "h", "heu":               relative = now.addingTimeInterval(n * 3600)
            case "sem":                    relative = now.addingTimeInterval(n * 7 * 86400)
            default:                       relative = now.addingTimeInterval(n * 86400)
            }
            cut(#"\bdans\s+\d{1,3}\s*(min|minutes?|h|heures?|j|jours?|sem|semaines?)\b"#)
        }

        // --- jours ---
        if relative == nil {
            if low.contains(" apres-demain ") { day = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)); cut(#"\bapr[eè]s-demain\b"#) }
            else if low.contains(" demain ")   { day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)); cut(#"\bdemain\b"#) }
            else if low.contains(" aujourd") || low.contains(" auj ") { day = cal.startOfDay(for: now); cut(#"\baujourd'?hui\b|\bauj\b"#) }

            let weekdays = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
            for (i, w) in weekdays.enumerated() where low.contains(" \(w) ") {
                day = next(weekday: i + 1, from: now, cal: cal)
                cut("\\b\(w)\\b")
                break
            }

            // « le 15 » / « le 15/03 » / « 15/3 »
            if let m = firstMatch(low, #"\ble\s+(\d{1,2})(?:[/\.](\d{1,2}))?\b"#) ?? firstMatch(low, #"\b(\d{1,2})[/\.](\d{1,2})\b"#) {
                var c = DateComponents()
                c.day = Int(m[1])
                c.month = m[2].isEmpty ? cal.component(.month, from: now) : Int(m[2])
                c.year = cal.component(.year, from: now)
                if let d = cal.date(from: c) {
                    day = d < cal.startOfDay(for: now) ? cal.date(byAdding: .year, value: 1, to: d) : d
                }
                cut(#"\ble\s+\d{1,2}(?:[/\.]\d{1,2})?\b"#); cut(#"\b\d{1,2}[/\.]\d{1,2}\b"#)
            }
        }

        // --- moments de la journée ---
        if hour == nil {
            if low.contains(" ce soir ") || low.contains(" cesoir ") { hour = (19, 0); cut(#"\bce\s*soir\b"#) }
            else if low.contains(" ce matin ") { hour = (9, 0); cut(#"\bce\s*matin\b"#) }
            else if low.contains(" cet aprem ") || low.contains(" cet apres-midi ") || low.contains(" cet aprèm ") {
                hour = (14, 0); cut(#"\bcet?\s*apr[eè]?m?(-?midi)?\b"#)
            } else if low.contains(" midi ") { hour = (12, 0); cut(#"\bmidi\b"#) }
        }

        // --- heure explicite : « à 9h », « 9h30 », « 14:00 », « 9 h » ---
        if hour == nil,
           let m = firstMatch(low, #"\b(?:a\s+)?(\d{1,2})\s*[:h]\s*(\d{2})?\b"#) {
            let h = Int(m[1]) ?? 0, mn = Int(m[2]) ?? 0
            if h < 24, mn < 60 {
                hour = (h, mn)
                cut(#"\b(?:[aà]\s+)?\d{1,2}\s*[:h]\s*(\d{2})?\b"#)
            }
        }

        // --- assemblage ---
        var due: Date?
        var timed = false
        if let relative {
            due = relative; timed = true
        } else {
            let base = day ?? (hour != nil ? cal.startOfDay(for: now) : nil)
            if let base {
                if let hr = hour {
                    due = cal.date(bySettingHour: hr.h, minute: hr.m, second: 0, of: base)
                    timed = true
                } else {
                    due = base
                }
            }
        }

        let title = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return Result(title: title.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : title,
                      due: due, timed: timed)
    }

    private static func next(weekday: Int, from now: Date, cal: Calendar) -> Date {
        let today = cal.component(.weekday, from: now)
        var delta = (weekday - today + 7) % 7
        if delta == 0 { delta = 7 }   // « lundi » = lundi prochain, pas aujourd'hui
        return cal.date(byAdding: .day, value: delta, to: cal.startOfDay(for: now))!
    }

    /// Groupes de capture par numéro : `m[1]`, `m[2]`… ("" si absent).
    private struct Groups { let raw: [String]; subscript(i: Int) -> String { i < raw.count ? raw[i] : "" } }

    private static func firstMatch(_ s: String, _ pattern: String) -> Groups? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return Groups(raw: (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        })
    }
}
