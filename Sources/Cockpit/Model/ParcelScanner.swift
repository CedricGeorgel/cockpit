import Foundation

/// Repère les colis en cours à partir des mails de transporteurs / marchands
/// (Mail.app, via AppleScript). Aucun appel aux API transporteurs : le numéro
/// de suivi et l'état sont extraits du mail, et le bouton « Suivre » ouvre la
/// page de suivi du transporteur.
enum ParcelScanner {

    enum Carrier: String, CaseIterable {
        case colissimo, chronopost, mondialRelay, relaisColis, colisPrive
        case ups, fedex, dhl, dpd, gls, amazon, other

        var display: String {
            switch self {
            case .colissimo:   return "Colissimo"
            case .chronopost:  return "Chronopost"
            case .mondialRelay: return "Mondial Relay"
            case .relaisColis: return "Relais Colis"
            case .colisPrive:  return "Colis Privé"
            case .ups:         return "UPS"
            case .fedex:       return "FedEx"
            case .dhl:         return "DHL"
            case .dpd:         return "DPD"
            case .gls:         return "GLS"
            case .amazon:      return "Amazon"
            case .other:       return "Colis"
            }
        }

        static func detect(_ haystack: String) -> Carrier {
            let s = haystack.folding(options: .diacriticInsensitive, locale: nil).lowercased()
            if s.contains("chronopost") { return .chronopost }
            if s.contains("colissimo") { return .colissimo }
            if s.contains("mondial relay") || s.contains("mondialrelay") { return .mondialRelay }
            if s.contains("relais colis") || s.contains("relaiscolis") { return .relaisColis }
            if s.contains("colis prive") || s.contains("colisprive") { return .colisPrive }
            if s.contains("laposte") || s.contains("la poste") { return .colissimo }
            if s.contains("ups.com") || s.contains("united parcel") { return .ups }
            if s.contains("fedex") { return .fedex }
            if s.contains("dhl") { return .dhl }
            if s.contains("dpd") { return .dpd }
            if s.contains("gls-group") || s.contains("gls-france") || s.contains(" gls ") { return .gls }
            if s.contains("amazon") { return .amazon }
            return .other
        }

        /// Motifs de numéro de suivi, du plus spécifique au plus large.
        var patterns: [String] {
            switch self {
            case .ups:          return [#"\b1Z[0-9A-Z]{16}\b"#]
            case .colissimo:    return [#"\b[0-9A-Z]{2}[0-9]{9}FR\b"#, #"\b6[AMTKLJ][0-9]{11}\b"#, #"\b[0-9]{13}\b"#]
            case .chronopost:   return [#"\b[A-Z]{2}[0-9]{9}[A-Z]{2}\b"#, #"\b[0-9]{13}\b"#]
            case .fedex:        return [#"\b[0-9]{15}\b"#, #"\b[0-9]{12}\b"#]
            case .dhl:          return [#"\bJD[0-9]{16,20}\b"#, #"\b[0-9]{10,11}\b"#]
            case .dpd:          return [#"\b[0-9]{14}\b"#, #"\b[0-9]{4}\s?[0-9]{4}\s?[0-9]{4}\s?[0-9]{2}\b"#]
            case .gls:          return [#"\b[0-9]{11,14}\b"#]
            case .mondialRelay: return [#"\b[0-9]{8}\b"#, #"\b[0-9]{11,12}\b"#]
            case .relaisColis:  return [#"\b[0-9]{10}[A-Z]?\b"#]
            case .colisPrive:   return [#"\b[0-9]{10,14}\b"#]
            case .amazon:       return [#"\bTBA[0-9]{9,15}\b"#]   // numéro de suivi Amazon (pas la réf. de commande)
            case .other:        return [#"\b[A-Z]{2}[0-9]{9}[A-Z]{2}\b"#, #"\b1Z[0-9A-Z]{16}\b"#]
            }
        }

        func trackingURL(_ number: String?) -> URL? {
            guard let n = number?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                if self == .amazon { return URL(string: "https://www.amazon.fr/gp/css/order-history") }
                return nil
            }
            let s: String
            switch self {
            case .colissimo:    s = "https://www.laposte.fr/outils/suivre-vos-envois?code=\(n)"
            case .chronopost:   s = "https://www.chronopost.fr/tracking-no-cms/suivi-page?listeNumerosLT=\(n)"
            case .mondialRelay: s = "https://www.mondialrelay.fr/suivi-de-colis/?numeroExpedition=\(n)"
            case .relaisColis:  s = "https://www.relaiscolis.com/suivi-de-colis/#/\(n)"
            case .colisPrive:   s = "https://www.colisprive.fr/moncolis/pages/detailColis.aspx?numColis=\(n)"
            case .ups:          s = "https://www.ups.com/track?tracknum=\(n)"
            case .fedex:        s = "https://www.fedex.com/fedextrack/?trknbr=\(n)"
            case .dhl:          s = "https://www.dhl.com/fr-fr/home/tracking.html?tracking-id=\(n)"
            case .dpd:          s = "https://www.dpd.fr/trace/\(n)"
            case .gls:          s = "https://gls-group.com/FR/fr/suivi-colis?match=\(n)"
            case .amazon:       s = "https://www.amazon.fr/gp/css/order-history"
            case .other:        s = "https://t.17track.net/fr#nums=\(n)"
            }
            return URL(string: s)
        }
    }

    enum Status: Int, Comparable {
        case announced, inTransit, outForDelivery, readyForPickup, issue, delivered
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .announced:      return "Préparé"
            case .inTransit:      return "En transit"
            case .outForDelivery: return "En livraison"
            case .readyForPickup: return "À retirer"
            case .issue:          return "Incident"
            case .delivered:      return "Livré"
            }
        }

        static func detect(_ text: String) -> Status {
            let s = text.folding(options: .diacriticInsensitive, locale: nil).lowercased()
            func has(_ any: [String]) -> Bool { any.contains { s.contains($0) } }
            if has(["colis livre", "a ete livre", "bien ete livre", "delivered", "remis a", "votre colis livre"]) {
                return .delivered
            }
            if has(["echec de livraison", "incident", "probleme de livraison", "retarde", "delayed",
                    "impossible de livrer", "retour a l'expediteur", "action requise", "en instance"]) {
                return .issue
            }
            if has(["point relais", "disponible en", "a retirer", "pret pour le retrait", "ready for pickup",
                    "disponible des", "en point retrait", "a recuperer", "mis a disposition"]) {
                return .readyForPickup
            }
            if has(["en cours de livraison", "out for delivery", "sera livre aujourd", "livraison aujourd",
                    "arrive aujourd", "dans le vehicule", "livreur", "livraison prevue aujourd"]) {
                return .outForDelivery
            }
            if has(["en transit", "expedie", "pris en charge", "shipped", "on its way", "en route",
                    "a quitte", "arrive au centre", "prise en charge", "colis confie"]) {
                return .inTransit
            }
            return .announced
        }
    }

    struct Parcel: Identifiable {
        let id: String
        var carrier: Carrier
        var number: String?
        var status: Status
        var date: Date
        var merchant: String
        var subject: String

        /// Priorité d'affichage : ce qui demande une action d'abord.
        var sortRank: Int {
            switch status {
            case .issue:          return 0
            case .readyForPickup: return 1
            case .outForDelivery: return 2
            case .inTransit:      return 3
            case .announced:      return 4
            case .delivered:      return 5
            }
        }
    }

    // MARK: Scan

    static func scan(days: Int = 21) throws -> [Parcel] {
        let raw = try OSAScript.run(script(days: days))
        if raw.hasPrefix("«ERR»") { throw NSError(domain: "Parcel", code: 1,
            userInfo: [NSLocalizedDescriptionKey: String(raw.dropFirst(5))]) }

        var byKey: [String: Parcel] = [:]
        for rec in raw.components(separatedBy: "«R»") where !rec.isEmpty {
            let f = rec.components(separatedBy: "«F»")
            guard f.count >= 4 else { continue }
            let subject = f[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let sender = f[1]
            let date = AppleMailBridge.appleDate(f[2])
            let body = f[3]

            let carrier = Carrier.detect(sender + " " + subject + " " + body.prefix(400))
            let number = trackingNumber(carrier: carrier, subject: subject, body: body)
            let status = Status.detect(subject + " \n " + body)
            let merchant = merchantName(sender: sender, carrier: carrier)

            // On ne garde que ce qui ressemble vraiment à un envoi : soit un
            // numéro de suivi, soit un vocabulaire d'expédition explicite. Les
            // enquêtes, newsletters et promos des transporteurs sont écartées.
            let folded = (subject + " " + body).folding(options: .diacriticInsensitive, locale: nil).lowercased()
            let subjSender = (subject + " " + sender).folding(options: .diacriticInsensitive, locale: nil).lowercased()
            let shipmentCues = ["expedi", "en cours de livraison", "colis", "point relais", "pris en charge",
                                "pret pour le retrait", "prete pour le retrait", "en transit", "out for delivery",
                                "has shipped", "on its way", "livraison prevue", "a ete livre", "bien ete livre",
                                "suivi de votre", "numero de suivi", "votre envoi", "mis a disposition"]
            let junkCues = ["enquete", "etude", "sondage", "questionnaire", "newsletter", "offre speciale",
                            "-50", "-40", "-30", "code promo", "bon plan", "parrainage", "votre avis",
                            "soldes", "black friday", "recrutement", "facture"]
            // Adresse d'expéditeur : la partie locale (avant @) trahit un mail
            // transactionnel (« expedition@ », « auto-confirm@ ») ou marketing
            // (« annonce@ », « newsletter@ »).
            let localPart = (sender.range(of: "<").map { String(sender[$0.upperBound...]) } ?? sender)
                .split(separator: "@").first.map(String.init)?
                .folding(options: .diacriticInsensitive, locale: nil).lowercased() ?? ""
            let marketingSender = ["annonce", "newsletter", "communication", "marketing", "news",
                                   "promo", "offre", "hello", "bonjour", "contact", "info", "actu",
                                   "no-reply@no-reply"].contains { localPart.contains($0) }
            let txSender = Carrier.detect(sender) != .other
                || ["expedition", "envoi", "auto-confirm", "shipment", "tracking", "suivi", "livraison",
                    "delivery", "order", "commande", "colis", "dispatch", "ship"].contains { localPart.contains($0) }

            // Sujets qui ne sont jamais des envois, quoi qu'ils contiennent.
            let hardBlock = marketingSender || [
                "facturation", "facture", "conditions", "politique de", "action urgente",
                "action requise", "verification", "verifier votre", "securite de votre", "mot de passe",
                "connexion inhabituelle", "abonnement", "renouvellement", "moyen de paiement",
                "prime video", "prime music", "kindle", "recompense", "cadeau", "vos points"
            ].contains { subjSender.contains($0) }
                || (number == nil && junkCues.contains { subjSender.contains($0) })

            let strongCue = ["numero de suivi", "suivi de votre colis", "votre colis a ete expedie",
                             "votre commande a ete expediee", "tracking number", "suivre mon colis",
                             "prepare pour l'expedition", "remis au transporteur"].contains { folded.contains($0) }

            let looksShipment = !hardBlock && (
                (number != nil && !marketingSender)
                || strongCue
                || (txSender && shipmentCues.contains { folded.contains($0) }))
            guard looksShipment else { continue }
            if carrier == .other, number == nil { continue }

            let key = number ?? "\(carrier.rawValue)|\(merchant.lowercased())"

            let parcel = Parcel(id: key, carrier: carrier, number: number, status: status,
                                date: date, merchant: merchant, subject: subject)
            if let existing = byKey[key] {
                // On garde le mail le plus récent (état le plus à jour).
                if date >= existing.date { byKey[key] = parcel }
            } else {
                byKey[key] = parcel
            }
        }

        let now = Date()
        return byKey.values
            .filter { p in
                // Les colis livrés il y a plus de 4 jours disparaissent.
                guard p.status == .delivered else { return true }
                return now.timeIntervalSince(p.date) < 4 * 86_400
            }
            .sorted { ($0.sortRank, $1.date) < ($1.sortRank, $0.date) }
    }

    // MARK: Extraction du numéro

    private static func trackingNumber(carrier: Carrier, subject: String, body: String) -> String? {
        // 1. Dans l'objet (souvent le plus fiable).
        if let n = firstMatch(carrier.patterns, in: subject) { return n }
        // 2. Dans le corps, à proximité d'un mot-clé de suivi.
        let low = body.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        let cues = ["suivi", "tracking", "numero de colis", "n° de colis", "n°", "numero d'expedition",
                    "shipment", "colis n", "reference", "track"]
        for cue in cues {
            var searchStart = low.startIndex
            while let r = low.range(of: cue, range: searchStart..<low.endIndex) {
                let lo = low.index(r.lowerBound, offsetBy: -10, limitedBy: low.startIndex) ?? low.startIndex
                let hi = low.index(r.upperBound, offsetBy: 90, limitedBy: low.endIndex) ?? low.endIndex
                let windowLow = String(low[lo..<hi])
                // Fenêtre correspondante dans le texte d'origine (mêmes offsets).
                let oLo = body.index(body.startIndex, offsetBy: low.distance(from: low.startIndex, to: lo),
                                     limitedBy: body.endIndex) ?? body.startIndex
                let oHi = body.index(body.startIndex, offsetBy: low.distance(from: low.startIndex, to: hi),
                                     limitedBy: body.endIndex) ?? body.endIndex
                let window = String(body[oLo..<oHi])
                if let n = firstMatch(carrier.patterns, in: window), !isNoise(n, context: windowLow) {
                    return n
                }
                searchStart = r.upperBound
            }
        }
        return nil
    }

    private static func firstMatch(_ patterns: [String], in text: String) -> String? {
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let m = re.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                return String(text[r]).replacingOccurrences(of: " ", with: "")
            }
        }
        return nil
    }

    /// Écarte les faux positifs évidents (montants, dates, numéros de commande).
    private static func isNoise(_ n: String, context: String) -> Bool {
        if context.contains("commande") && n.count < 10 { return true }
        if context.contains("montant") || context.contains("total") || context.contains("eur") { return true }
        if n.allSatisfy({ $0 == "0" }) { return true }
        return false
    }

    private static func merchantName(sender: String, carrier: Carrier) -> String {
        // « Nom <adresse@domaine> » → « Nom », nettoyé du transporteur.
        var name = sender
        if let lt = sender.firstIndex(of: "<") { name = String(sender[..<lt]) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        let low = name.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        if name.isEmpty || low.contains("no-reply") || low.contains("noreply") || low.contains("notification") {
            if let at = sender.firstIndex(of: "@"), let lt = sender.firstIndex(of: "<") {
                let domain = sender[sender.index(after: at)...].prefix { $0 != ">" }
                let host = domain.split(separator: ".").dropLast().last.map(String.init) ?? String(domain)
                _ = lt
                return host.capitalized
            }
            return carrier.display
        }
        return name
    }

    // MARK: AppleScript

    private static func script(days: Int) -> String {
        """
        set outStr to ""
        set hints to {"colissimo", "chronopost", "laposte", "mondial relay", "mondialrelay", "ups.com", "fedex", "dhl", "dpd", "gls-", "colisprive", "colis prive", "relais colis", "relaiscolis", "amazon.fr", "amazon.com", "boxtal", "sendcloud", "shippingbo", "expedi", "votre colis", "suivi de commande", "suivi de votre", "numero de suivi", "tracking number", "en cours de livraison", "colis livre", "point relais", "pret pour le retrait", "out for delivery", "has shipped", "on its way", "prepare pour expedition"}
        tell application "Mail"
        \tif it is not running then return "«ERR»Mail n'est pas lancé"
        \trepeat with acc in (every account whose enabled is true)
        \t\tset theBox to missing value
        \t\ttry
        \t\t\tset theBox to mailbox "INBOX" of acc
        \t\tend try
        \t\tif theBox is missing value then
        \t\t\trepeat with aBox in mailboxes of acc
        \t\t\t\tset bn to (name of aBox as string)
        \t\t\t\tif bn is "INBOX" or bn contains "réception" or bn contains "Reception" or bn contains "Posteingang" then
        \t\t\t\t\tset theBox to aBox
        \t\t\t\t\texit repeat
        \t\t\t\tend if
        \t\t\tend repeat
        \t\tend if
        \t\tif theBox is not missing value then
        \t\t\tset cutoff to (current date) - (\(days) * days)
        \t\t\tset msgs to {}
        \t\t\ttry
        \t\t\t\tset msgs to (messages of theBox whose date received > cutoff)
        \t\t\tend try
        \t\t\trepeat with aMsg in msgs
        \t\t\t\tset theSubject to ""
        \t\t\t\ttry
        \t\t\t\t\tset theSubject to subject of aMsg
        \t\t\t\tend try
        \t\t\t\tset theSender to ""
        \t\t\t\ttry
        \t\t\t\t\tset theSender to sender of aMsg
        \t\t\t\tend try
        \t\t\t\tset hay to (theSubject & " " & theSender)
        \t\t\t\tset matched to false
        \t\t\t\tignoring diacriticals
        \t\t\t\t\trepeat with h in hints
        \t\t\t\t\t\tif hay contains h then
        \t\t\t\t\t\t\tset matched to true
        \t\t\t\t\t\t\texit repeat
        \t\t\t\t\t\tend if
        \t\t\t\t\tend repeat
        \t\t\t\tend ignoring
        \t\t\t\tif matched then
        \t\t\t\t\tset theDate to ((date received of aMsg) as string)
        \t\t\t\t\tset msgBody to ""
        \t\t\t\t\ttry
        \t\t\t\t\t\tset msgBody to (content of aMsg)
        \t\t\t\t\tend try
        \t\t\t\t\tif (count of msgBody) > 4000 then set msgBody to (text 1 thru 4000 of msgBody)
        \t\t\t\t\tset outStr to outStr & theSubject & "«F»" & theSender & "«F»" & theDate & "«F»" & msgBody & "«R»"
        \t\t\t\tend if
        \t\t\tend repeat
        \t\tend if
        \tend repeat
        end tell
        return outStr
        """
    }
}
