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

    private static let trainTerms = [
        "gare", "tgv", "ouigo", "inoui", "sncf", "train", "eurostar", "thalys", "ter ",
        "intercités", "lyria", "renfe", "trenitalia", "trainline", "db ", "ice ", "railjet",
        "gare de l'est", "gare du nord", "gare de lyon", "montparnasse", "saint-lazare",
        "austerlitz", "part-dieu", "matabiau", "perrache", "guillemins", "flixtrain",
    ]
    private static let flightTerms = ["vol ", "flight", "aéroport", "airport", "boarding",
                                      "embarquement", "easyjet", "ryanair", "air france", "klm",
                                      "lufthansa", "transavia", "vueling", "wizz air", "volotea",
                                      "porte d'embarquement", "gate ", "terminal "]
    private static let boatTerms = ["ferry", "traversée", "corsica", "brittany ferries", "dfds",
                                    "la méridionale", "port de", "embarcadère", "navire"]
    private static let busTerms = ["flixbus", "blablacar bus", "blablabus", "car ", "autocar", "gare routière"]

    static func compute(_ events: [AgendaItem], mails: [MailModel.Mail] = [], now: Date = Date()) -> [Trip] {
        let horizon = now.addingTimeInterval(6 * 86_400)
        var trips = events.compactMap { e -> Trip? in
            guard let start = e.start, start > now.addingTimeInterval(-3600), start < horizon,
                  !e.allDay else { return nil }
            let hay = (e.title + " " + (e.location ?? "")).folding(options: .diacriticInsensitive, locale: nil).lowercased()
            guard let mode = detect(hay, title: e.title) else { return nil }
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
                  let mode = detect(hay, title: m.subject) else { continue }
            // déjà couvert par un évènement agenda ?
            if trips.contains(where: { abs(($0.receivedAt ?? .distantPast).timeIntervalSince(m.date)) < 86_400 }) { continue }
            trips.append(Trip(id: "mail-\(m.id)", title: m.subject, origin: "",
                              departure: nil, arrival: nil, mode: mode,
                              messageID: m.messageID, receivedAt: m.date))
        }

        return trips.sorted {
            ($0.departure ?? .distantFuture, $0.receivedAt ?? .distantPast)
                < ($1.departure ?? .distantFuture, $1.receivedAt ?? .distantPast)
        }
    }

    private static func detect(_ hay: String, title: String) -> Trip.Mode? {
        if flightTerms.contains(where: hay.contains)      { return .flight }
        if boatTerms.contains(where: hay.contains)        { return .boat }
        if busTerms.contains(where: hay.contains)         { return .bus }
        if trainTerms.contains(where: hay.contains)       { return .train }
        if looksLikeRoute(title)                          { return .train }
        return nil
    }

    /// « Strasbourg - Paris Gare de l'Est », « Lyon → Marseille »…
    private static func looksLikeRoute(_ title: String) -> Bool {
        let separators = [" - ", " – ", " → ", " > ", " / ", " vers ", " to "]
        guard let sep = separators.first(where: title.contains) else { return false }
        let parts = title.components(separatedBy: sep)
        guard parts.count == 2 else { return false }
        // deux segments courts, plutôt des lieux
        return parts.allSatisfy { $0.split(separator: " ").count <= 5 && !$0.isEmpty }
    }

    private static func originGuess(_ e: AgendaItem) -> String {
        for sep in [" - ", " – ", " → ", " > ", " vers ", " to "] {
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
        HStack(spacing: 9) {
            Image(systemName: t.mode.icon)
                .font(.system(size: 13)).foregroundStyle(Theme.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                if let dep = t.departure {
                    Text(countdown(to: dep)).font(.ui(9)).foregroundStyle(Theme.textFaint)
                } else if let r = t.receivedAt {
                    Text("billet reçu \(Fmt.relday(r))").font(.ui(9)).foregroundStyle(Theme.textFaint)
                }
            }
            Spacer(minLength: 4)
            if let dep = t.departure {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.shortTime(dep)).font(.num(14, .semibold)).foregroundStyle(Theme.text)
                    Text(Fmt.relday(dep)).font(.ui(8.5)).foregroundStyle(Theme.textFaint)
                }
                if let url = TripsDigest.mapsURL(for: t.origin) {
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
