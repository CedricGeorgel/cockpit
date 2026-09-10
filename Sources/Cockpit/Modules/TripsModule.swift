import SwiftUI
import AppKit

/// Trajets détectés dans l'agenda (train surtout). Comme le suivi de colis :
/// la carte n'apparaît que si quelque chose est détecté.
struct Trip: Identifiable {
    enum Mode { case train, flight, boat, bus
        var icon: String {
            switch self { case .train: return "tram.fill"; case .flight: return "airplane"
            case .boat: return "ferry.fill"; case .bus: return "bus.fill" }
        }
    }
    let id: String
    var title: String        // libellé de l'évènement / du mail
    var origin: String       // gare / lieu de départ deviné (agenda seulement)
    var departure: Date?     // nil = déduit d'un mail, heure inconnue
    var arrival: Date?
    var mode: Mode
    var messageID: String?   // pour rouvrir le mail
    var receivedAt: Date?    // date du mail
}

enum TripsDigest {

    /// Où en est le trajet, pour savoir quelle heure montrer (ou s'il faut le masquer).
    enum Phase { case upcoming, inTransit, done, ticket }

    static func phase(_ t: Trip, now: Date = Date()) -> Phase {
        guard let dep = t.departure else { return .ticket }
        if now < dep { return .upcoming }
        let end = t.arrival ?? dep.addingTimeInterval(3 * 3600)   // durée par défaut si l'agenda n'a pas de fin
        return now > end.addingTimeInterval(60) ? .done : .inTransit
    }

    // Termes forts : peu de risque de faux positif dans un titre d'évènement.
    private static let trainTerms = [
        "tgv", "ouigo", "inoui", "sncf", "eurostar", "thalys", "lyria", "renfe",
        "trenitalia", "trainline", "railjet", "flixtrain", "intercités", "intercite",
        "billet train", "gare de l'est", "gare du nord", "gare de lyon", "gare montparnasse",
        "gare saint-lazane", "gare d'austerlitz", "gare part-dieu", "gare matabiau",
    ]
    private static let flightTerms = ["vol ", "flight ", "boarding pass", "carte d'embarquement",
                                      "en avion", "easyjet", "ryanair", "air france", " klm ",
                                      "lufthansa", "transavia", "vueling", "wizz air", "volotea",
                                      "porte d'embarquement"]
    private static let boatTerms = ["ferry", "traversée", "corsica linea", "corsica ferries",
                                    "brittany ferries", " dfds ", "la méridionale", "embarcadère"]
    private static let busTerms = ["flixbus", "blablacar bus", "blablabus", "autocar", "gare routière"]

    /// Ce qui, dans un titre, indique clairement autre chose qu'un déplacement.
    private static let notTrip = [
        "rdv", "rendez-vous", "reunion", "meeting", "call ", "visio", "point ", "appel ",
        "dejeuner", "dej ", "diner", "brunch", "cafe ", "apero", "gouter",
        "anniversaire", "anniv", "dentiste", "medecin", "docteur", " kine", " osteo", " psy",
        "coiffeur", "resto", "restaurant", "entretien", "cours ", " sport", "seance", "atelier",
        "formation", "livraison", "shooting", "tournage", "demenagement", " menage", "reparation",
        "signature", "notaire", " banque", "assurance", " mairie", "prefecture",
        "gobelins", "campus", "amphi", "(salle", "conference", "conferences", "rentree",
        "promo ", "td ", "tp ", " cm ", "workshop", "jury", "soutenance", "partiel",
    ]

    private static let cities: Set<String> = [
        "paris", "lyon", "marseille", "lille", "strasbourg", "bordeaux", "toulouse", "nantes",
        "nice", "rennes", "montpellier", "grenoble", "dijon", "reims", "metz", "nancy", "mulhouse",
        "tours", "angers", "brest", "havre", "rouen", "caen", "orleans", "clermont", "amiens",
        "besancon", "avignon", "aix", "cannes", "perpignan", "poitiers", "limoges", "colmar",
        "bruxelles", "londres", "geneve", "luxembourg", "francfort", "amsterdam", "barcelone",
        "madrid", "milan", "turin", "berlin", "cologne", "zurich", "bale",
    ]

    static func compute(_ events: [AgendaItem], mails: [MailModel.Mail] = [], now: Date = Date()) -> [Trip] {
        let horizon = now.addingTimeInterval(6 * 86_400)
        var trips = events.compactMap { e -> Trip? in
            guard let start = e.start, start < horizon,
                  start > now.addingTimeInterval(-18 * 3600), !e.allDay else { return nil }
            // On ne détecte QUE sur le titre : l'adresse d'un RDV contient
            // souvent « gare », « avenue », etc. et créait de faux trajets.
            guard let mode = detect(title: e.title) else { return nil }
            return Trip(id: e.id, title: e.title, origin: originGuess(e),
                        departure: start, arrival: e.end, mode: mode)
        }

        // Mails de réservation (billets) : pas d'heure, juste un rappel + lien.
        let bookingCues = ["billet", "e-billet", "reservation", "confirmation de commande",
                           "carte d'embarquement", "boarding pass", "votre voyage", "itineraire",
                           "confirmation de voyage", "votre trajet", "convocation voyage"]
        let cutoff = now.addingTimeInterval(-10 * 86_400)
        for m in mails where m.date > cutoff {
            let hay = (m.subject + " " + m.fromName + " " + m.fromAddress)
                .folding(options: .diacriticInsensitive, locale: nil).lowercased()
            guard bookingCues.contains(where: hay.contains),
                  let mode = detect(title: m.subject + " " + m.fromName) else { continue }
            // déjà couvert par un évènement agenda ?
            if trips.contains(where: { abs(($0.receivedAt ?? .distantPast).timeIntervalSince(m.date)) < 86_400 }) { continue }
            trips.append(Trip(id: "mail-\(m.id)", title: m.subject, origin: "",
                              departure: nil, arrival: nil, mode: mode,
                              messageID: m.messageID, receivedAt: m.date))
        }

        return trips
            .filter { phase($0, now: now) != .done }   // 1 min après l'arrivée : on retire le trajet
            .sorted {
                ($0.departure ?? .distantFuture, $0.receivedAt ?? .distantPast)
                    < ($1.departure ?? .distantFuture, $1.receivedAt ?? .distantPast)
            }
    }

    private static func detect(title raw: String) -> Trip.Mode? {
        let t = raw.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        if notTrip.contains(where: t.contains) { return nil }
        if flightTerms.contains(where: t.contains) { return .flight }
        if boatTerms.contains(where: t.contains)   { return .boat }
        if busTerms.contains(where: t.contains)    { return .bus }
        if trainTerms.contains(where: t.contains)  { return .train }
        // « train » / « gare » seuls : seulement s'ils sont vraiment dans le titre
        if t.range(of: #"\b(train|gare|aeroport)\b"#, options: .regularExpression) != nil,
           looksLikeRoute(raw) { return t.contains("aeroport") ? .flight : .train }
        if looksLikeRoute(raw) { return .train }
        return nil
    }

    /// « Strasbourg → Paris », « Lyon - Marseille ». Strict : deux lieux courts,
    /// pas de mot de liaison, et pour le tiret il faut une ville connue.
    private static func looksLikeRoute(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        // Une vraie destination ne contient ni parenthèse (« (salle 310) », « (groupe B) »)
        // ni « / » (« Cours / Atelier », « MDPSN / Rentrée »).
        if t.contains("(") || t.contains(" / ") || t.contains("/") { return false }
        let arrows = [" → ", " -> ", " > "]
        let dashes = [" - ", " – ", " — "]
        let sep = arrows.first(where: t.contains) ?? dashes.first(where: t.contains)
        guard let sep else { return false }
        let parts = t.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }

        let stop: Set<String> = ["le", "la", "les", "chez", "avec", "et", "pour", "salle",
                                 "bureau", "room", "zoom", "teams", "meet", "part", "partie",
                                 "acte", "ep", "épisode", "vs", "contre"]
        for p in parts {
            let words = p.folding(options: .diacriticInsensitive, locale: nil)
                .lowercased().split(separator: " ").map(String.init)
            guard (1...4).contains(words.count) else { return false }
            if words.contains(where: stop.contains) { return false }
            // premier mot doit commencer par une majuscule dans l'original
            guard p.first?.isUppercase == true || p.first?.isNumber == true else { return false }
        }
        // Avec un tiret (très courant dans les titres), on exige une ville connue.
        if arrows.first(where: t.contains) == nil {
            let allWords = parts.flatMap {
                $0.folding(options: .diacriticInsensitive, locale: nil).lowercased().split(separator: " ").map(String.init)
            }
            return allWords.contains { cities.contains($0) }
        }
        return true
    }

    private static func originGuess(_ e: AgendaItem) -> String {
        for sep in [" → ", " -> ", " > ", " - ", " – ", " — "] {
            if let r = e.title.range(of: sep) {
                return String(e.title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        if let loc = e.location, loc.folding(options: .diacriticInsensitive, locale: nil).lowercased().contains("gare") {
            return loc
        }
        return e.location ?? e.title
    }

    /// Ouvre Plans en itinéraire (transports) vers la gare de départ.
    static func mapsURL(for origin: String) -> URL? {
        let q = ("gare " + origin).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? origin
        return URL(string: "maps://?daddr=\(q)&dirflg=r")
    }
}

// MARK: - Vue

struct TripsModule: View {
    @ObservedObject var calendar: CalendarModel
    @ObservedObject var mail: MailModel
    @State private var now = Date()
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var trips: [Trip] {
        TripsDigest.compute(calendar.events,
                            mails: mail.sources.flatMap { mail.state($0.id).mails }, now: now)
    }

    var body: some View {
        ModuleBody {
            VStack(alignment: .leading, spacing: 6) {
                if trips.isEmpty {
                    ModuleNotice(icon: "tram", title: "Aucun trajet à venir")
                } else {
                    ForEach(trips) { row($0) }
                }
                Spacer(minLength: 0)
            }
        }
        .onReceive(tick) { now = $0 }
    }

    private func row(_ t: Trip) -> some View {
        let phase = TripsDigest.phase(t, now: now)
        // En amont : heure de départ. Une fois parti : heure d'arrivée.
        let inTransit = phase == .inTransit
        let mainDate = inTransit ? (t.arrival ?? t.departure) : t.departure

        return HStack(spacing: 9) {
            Image(systemName: t.mode.icon)
                .font(.system(size: 13))
                .foregroundStyle(inTransit ? Theme.textDim : Theme.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                if inTransit, let arr = t.arrival {
                    Text("arrivée \(countdown(to: arr))").font(.ui(9)).foregroundStyle(Theme.textFaint)
                } else if inTransit {
                    Text("en cours").font(.ui(9)).foregroundStyle(Theme.textFaint)
                } else if let dep = t.departure {
                    Text(countdown(to: dep)).font(.ui(9)).foregroundStyle(Theme.textFaint)
                } else if let r = t.receivedAt {
                    Text("billet reçu \(Fmt.relday(r))").font(.ui(9)).foregroundStyle(Theme.textFaint)
                }
            }
            Spacer(minLength: 4)
            if let date = mainDate {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.shortTime(date)).font(.num(14, .semibold)).foregroundStyle(Theme.text)
                    Text(inTransit ? "arrivée" : Fmt.relday(date))
                        .font(.ui(8.5)).foregroundStyle(Theme.textFaint)
                }
                if !inTransit, let url = TripsDigest.mapsURL(for: t.origin) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: "map").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.info)
                    .help("Itinéraire vers \(t.origin)")
                }
            } else if let mid = t.messageID {
                Button { mail.openInMail(.init(id: "", fromName: "", fromAddress: "", subject: "",
                                               date: .now, seen: true, reason: .flagged, messageID: mid)) } label: {
                    Image(systemName: "envelope").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.info)
                .help("Ouvrir le mail")
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }

    private func countdown(to date: Date) -> String {
        let s = date.timeIntervalSince(now)
        if s < 0 { return "en cours" }
        if s < 3600 { return "dans \(Int(s / 60)) min" }
        if s < 86_400 { return "dans \(Int(s / 3600)) h" }
        return "dans \(Int(s / 86_400)) j"
    }
}
