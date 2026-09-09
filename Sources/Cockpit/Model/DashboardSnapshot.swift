import Foundation
import AppKit

/// Instantané complet du tableau de bord, sérialisé en JSON et publié vers le
/// serveur relais pour être affiché par la PWA mobile. En lecture seule côté
/// téléphone (les actions repassent par `RemoteCommand`).
struct DashboardSnapshot: Codable {
    var generatedAt: Date
    var device: String          // nom lisible (« MacBook de Cedric »)
    var deviceId: String = ""   // identifiant stable, rempli par RemoteBridge
    var platform: String = "mac"
    /// Identifiants des commandes déjà appliquées par le Mac (la PWA s'en sert
    /// pour retirer les actions en attente et les marquer « faites »).
    var appliedCommandIds: [String]

    var weather: Weather?
    var agenda: [Agenda]
    var todos: [Todo]
    var news: [News]
    var mail: MailBox
    var jobs: [Job]
    var parcels: [Parcel]
    var trips: [Trip]
    var battery: Battery
    var disk: Disk?
    var callTime: [Contact]
    var scratchpad: String
    var birthdays: [Birthday] = []

    struct Birthday: Codable, Identifiable {
        var id: String
        var name: String
        var date: Date
        var turning: Int?
    }

    struct Trip: Codable, Identifiable {
        var id: String
        var title: String
        var origin: String
        var departure: Date?      // absent = billet repéré dans un mail, heure inconnue
        var arrival: Date?        // heure d'arrivée (une fois parti, c'est elle qu'on affiche)
        var receivedAt: Date?
        var mode: String          // train | flight | boat | bus
        var mapsURL: String?
    }

    struct Weather: Codable {
        var place: String
        var temp: Int
        var feels: Int
        var tempMax: Int
        var tempMin: Int
        var text: String
        var symbol: String
        var humidity: Int
        var wind: Int
        var precipProb: Int
        var aqi: Int?
        var aqiLabel: String?
        var pollen: String?
        var advice: String?
    }

    struct Agenda: Codable, Identifiable {
        var id: String
        var title: String
        var start: Date?
        var end: Date?
        var allDay: Bool
        var location: String?
        var dayLabel: String
        var videoURL: String?
    }

    struct Todo: Codable, Identifiable {
        var id: String
        var title: String
        var overdue: Bool
        var due: Date?
    }

    struct News: Codable, Identifiable {
        var id: String
        var title: String
        var link: String?
        var source: String
        var date: Date?
    }

    struct MailBox: Codable {
        var accounts: [Account]
        var items: [Item]
        var otherUnread: Int
        struct Account: Codable { var name: String; var unread: Int }
        struct Item: Codable, Identifiable {
            var id: String
            var from: String
            var subject: String
            var date: Date
            var seen: Bool
            var reason: String        // flagged | work | contact | known
            var account: String
            var messageID: String
        }
    }

    struct Job: Codable, Identifiable {
        var id: String { company }
        var company: String
        var stage: Int
        var stageLabel: String
        var lastSubject: String
        var lastActivity: Date
        var address: String
        var contactable: Bool
    }

    struct Parcel: Codable, Identifiable {
        var id: String
        var carrier: String
        var number: String?
        var status: String
        var statusRank: Int
        var merchant: String
        var date: Date
        var trackingURL: String?
    }

    struct Battery: Codable {
        var mac: Mac?
        var devices: [Device]
        struct Mac: Codable {
            var percent: Int
            var charging: Bool
            var minutesRemaining: Int?
            var cycleCount: Int?
            var healthPercent: Int?
        }
        struct Device: Codable, Identifiable {
            var id: String { name }
            var name: String
            var icon: String
            var percent: Int
            var extra: String?
            var seenAt: Date?      // absent = lu à l'instant
        }
    }

    struct Disk: Codable {
        var volumeName: String
        var usedBytes: Int64
        var totalBytes: Int64
        var freeBytes: Int64
    }

}

// MARK: - Construction

enum SnapshotBuilder {

    @MainActor
    static func build(appliedCommandIds: [String]) -> DashboardSnapshot {
        let s = Services.shared

        // Météo
        var weather: DashboardSnapshot.Weather?
        if let w = s.weather.snapshot {
            weather = .init(
                place: w.place, temp: Int(w.temp.rounded()), feels: Int(w.feels.rounded()),
                tempMax: Int(w.tempMax.rounded()), tempMin: Int(w.tempMin.rounded()),
                text: wmoText(w.code), symbol: wmoIcon(w.code),
                humidity: w.humidity, wind: Int(w.wind.rounded()), precipProb: w.precipProb,
                aqi: w.aqi, aqiLabel: w.aqi.map(aqiLabel),
                pollen: w.topPollen.map { "\($0.name) \(pollenLabel($0.value))" },
                advice: w.advice)
        }

        // Agenda
        let agenda = s.calendar.events.map { e in
            DashboardSnapshot.Agenda(
                id: e.id, title: e.title, start: e.start, end: e.end, allDay: e.allDay,
                location: e.location,
                dayLabel: (e.start.map { Fmt.relday($0) } ?? "").capitalizedFirst,
                videoURL: e.videoURL?.absoluteString)
        }

        // À faire
        let todos = s.todos.items.map {
            DashboardSnapshot.Todo(id: $0.id, title: $0.title, overdue: $0.overdue, due: $0.due)
        }

        // Actualités
        let news = s.news.items.prefix(30).map {
            DashboardSnapshot.News(id: $0.id.uuidString, title: $0.title,
                                   link: $0.link?.absoluteString, source: $0.source, date: $0.date)
        }

        // Mails
        var seen = Set<String>()
        var mailItems: [DashboardSnapshot.MailBox.Item] = []
        var accounts: [DashboardSnapshot.MailBox.Account] = []
        var otherUnread = 0
        var allMails: [MailModel.Mail] = []
        for src in s.mail.sources {
            let st = s.mail.state(src.id)
            accounts.append(.init(name: src.name, unread: st.unread))
            otherUnread += st.otherUnread
            for m in st.mails where seen.insert(m.messageID.isEmpty ? m.id : m.messageID).inserted {
                allMails.append(m)
                mailItems.append(.init(
                    id: m.id, from: m.fromName, subject: m.subject, date: m.date, seen: m.seen,
                    reason: reasonKey(m.reason), account: m.account, messageID: m.messageID))
            }
        }
        mailItems.sort { ($0.seen ? 1 : 0, $1.date) < ($1.seen ? 1 : 0, $0.date) }
        let mail = DashboardSnapshot.MailBox(accounts: accounts, items: mailItems, otherUnread: otherUnread)

        // Candidatures
        let jobs = JobsDigest.compute(allMails).map { a in
            DashboardSnapshot.Job(
                company: a.company, stage: a.stage.rawValue, stageLabel: a.stage.label,
                lastSubject: a.lastSubject, lastActivity: a.lastActivity, address: a.address,
                contactable: a.stage != .rejected && JobsDigest.isContactable(a.address))
        }

        // Colis
        let parcels = s.parcels.parcels.map { p in
            DashboardSnapshot.Parcel(
                id: p.id, carrier: p.carrier.display, number: p.number,
                status: p.status.label, statusRank: p.sortRank, merchant: p.merchant, date: p.date,
                trackingURL: p.carrier.trackingURL(p.number)?.absoluteString)
        }

        // Trajets
        let allMailsForTrips = s.mail.sources.flatMap { s.mail.state($0.id).mails }
        let trips = TripsDigest.compute(s.calendar.events, mails: allMailsForTrips).map { t in
            DashboardSnapshot.Trip(
                id: t.id, title: t.title, origin: t.origin, departure: t.departure,
                arrival: t.arrival, receivedAt: t.receivedAt, mode: "\(t.mode)",
                mapsURL: t.origin.isEmpty ? nil : TripsDigest.mapsURL(for: t.origin)?.absoluteString)
        }

        // Batterie
        let battery = DashboardSnapshot.Battery(
            mac: s.battery.mac.map {
                .init(percent: $0.percent, charging: $0.charging, minutesRemaining: $0.minutesRemaining,
                      cycleCount: $0.cycleCount, healthPercent: $0.healthPercent)
            },
            devices: s.battery.localDevices.map {
                .init(name: $0.name, icon: $0.icon, percent: $0.percent, extra: $0.extra,
                      seenAt: $0.isLive ? nil : $0.lastSeen)
            })

        // Disque
        var disk: DashboardSnapshot.Disk?
        if s.disk.volumeTotal > 0 {
            disk = .init(volumeName: s.disk.volumeName, usedBytes: s.disk.volumeUsed,
                         totalBytes: s.disk.volumeTotal, freeBytes: s.disk.volumeFree)
        }

        let bdays = s.birthdays.upcoming.map {
            DashboardSnapshot.Birthday(id: $0.id, name: $0.name, date: $0.date, turning: $0.turning)
        }

        return DashboardSnapshot(
            generatedAt: Date(),
            device: Host.current().localizedName ?? "Mac",
            appliedCommandIds: appliedCommandIds,
            weather: weather, agenda: agenda, todos: todos, news: Array(news), mail: mail,
            jobs: jobs, parcels: parcels, trips: trips, battery: battery, disk: disk,
            callTime: CallTimeStore.decode(), scratchpad: ScratchStore.load(),
            birthdays: bdays)
    }

    private static func reasonKey(_ r: MailModel.Reason) -> String {
        switch r {
        case .flagged: return "flagged"
        case .keyword: return "keyword"
        case .work:    return "work"
        case .contact: return "contact"
        case .known:   return "known"
        }
    }
}
