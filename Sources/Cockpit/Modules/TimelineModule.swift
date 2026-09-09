import SwiftUI
import AppKit

/// « Aujourd'hui » : une seule colonne chronologique qui fusionne les évènements
/// de l'agenda, les trajets et les rappels avec heure. Un repère « maintenant ».
struct TimelineModule: View {
    @ObservedObject var calendar: CalendarModel
    @ObservedObject var todos: TodosModel
    @ObservedObject var mail: MailModel
    @ObservedObject var birthdays: BirthdaysModel
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    enum Kind { case event, trip, reminder, leave, birthday }

    struct Entry: Identifiable {
        let id: String
        let at: Date
        let kind: Kind
        let title: String
        let sub: String?
        var videoURL: URL?
        var mapsURL: URL?
        var done: Bool = false
    }

    static func entries(_ cal: CalendarModel, _ todos: TodosModel, _ mail: MailModel,
                        _ birthdays: BirthdaysModel, now: Date = Date()) -> [Entry] {
        let c = Calendar.current
        var out: [Entry] = []

        for b in birthdays.upcoming where b.isToday {
            out.append(Entry(id: "bday-\(b.id)", at: b.date, kind: .birthday,
                             title: "Anniversaire · \(b.name)",
                             sub: b.turning.map { "\($0) ans" }))
        }

        for e in cal.events {
            guard let s = e.start, !e.allDay, c.isDateInToday(s) else { continue }
            var sub = Fmt.shortTime(s)
            if let end = e.end { sub += "–\(Fmt.shortTime(end))" }
            if let loc = e.location { sub += " · \(loc)" }
            out.append(Entry(id: "ev-\(e.id)", at: s, kind: .event, title: e.title,
                             sub: sub, videoURL: e.videoURL))
        }

        let trips = TripsDigest.compute(cal.events,
            mails: mail.sources.flatMap { mail.state($0.id).mails }, now: now)
        for t in trips {
            guard let d = t.departure, c.isDateInToday(d) else { continue }
            let phase = TripsDigest.phase(t, now: now)
            if phase == .done { continue }
            let maps = t.origin.isEmpty ? nil : TripsDigest.mapsURL(for: t.origin)
            out.append(Entry(id: "trip-\(t.id)", at: d, kind: .trip,
                             title: t.title.isEmpty ? "Trajet" : t.title,
                             sub: phase == .inTransit ? "en cours" : Fmt.shortTime(d),
                             mapsURL: maps))
            // « Pars à » : départ moins la marge du mode.
            if phase == .upcoming {
                let leave = d.addingTimeInterval(-TripPlan.margin(t.mode))
                if leave > now.addingTimeInterval(-300) {
                    out.append(Entry(id: "leave-\(t.id)", at: leave, kind: .leave,
                                     title: "Partir pour \(t.origin.isEmpty ? "le trajet" : t.origin)",
                                     sub: "pour \(Fmt.shortTime(d))", mapsURL: maps))
                }
            }
        }

        for r in todos.items {
            guard let due = r.due, c.isDateInToday(due) else { continue }
            out.append(Entry(id: "rem-\(r.id)", at: due, kind: .reminder,
                             title: r.title, sub: Fmt.shortTime(due), done: false))
        }

        return out.sorted { $0.at < $1.at }
    }

    private var entries: [Entry] { Self.entries(calendar, todos, mail, birthdays, now: now) }

    /// Le prochain anniversaire à venir (pas aujourd'hui), pour un aperçu discret.
    private var nextBirthday: Birthday? {
        birthdays.upcoming.first { !$0.isToday && $0.inDays <= 10 }
    }

    var body: some View {
        ModuleBody {
            if entries.isEmpty && nextBirthday == nil {
                ModuleNotice(icon: "calendar.day.timeline.left", title: "Rien de prévu aujourd'hui")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                            if i > 0, entries[i - 1].at <= now, e.at > now {
                                nowMarker
                            }
                            row(e)
                        }
                        if let last = entries.last, last.at <= now { nowMarker }
                        if entries.isEmpty {
                            Text("Rien de prévu aujourd'hui")
                                .font(.ui(10.5)).foregroundStyle(Theme.textFaint).padding(.vertical, 4)
                        }
                        if let b = nextBirthday {
                            Divider().overlay(Theme.hairline).padding(.vertical, 4)
                            HStack(spacing: 6) {
                                Image(systemName: "gift.fill").font(.system(size: 9)).foregroundStyle(Theme.info)
                                Text("Anniv \(b.name) \(b.inDays == 1 ? "demain" : "dans \(b.inDays) j")"
                                     + (b.turning.map { " (\($0) ans)" } ?? ""))
                                    .font(.ui(9.5)).foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onReceive(tick) { now = $0 }
    }

    private var nowMarker: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.warn).frame(width: 6, height: 6)
            Rectangle().fill(Theme.warn.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func row(_ e: Entry) -> some View {
        let past = e.at < now
        HStack(alignment: .top, spacing: 8) {
            Text(Fmt.shortTime(e.at))
                .font(.num(10.5, .medium)).monospacedDigit()
                .foregroundStyle(past ? Theme.textFaint : Theme.textDim)
                .frame(width: 38, alignment: .trailing)
            Image(systemName: icon(e.kind))
                .font(.system(size: 10))
                .foregroundStyle(color(e.kind))
                .frame(width: 14).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.ui(11.5, .medium))
                    .foregroundStyle(past ? Theme.textDim : Theme.text)
                    .strikethrough(e.done)
                    .lineLimit(1)
                if let sub = e.sub {
                    Text(sub).font(.ui(9)).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let u = e.videoURL, past == false || Date() < e.at.addingTimeInterval(3600) {
                iconButton("video.fill") { NSWorkspace.shared.open(u) }
            } else if let m = e.mapsURL, e.kind == .leave || e.kind == .trip {
                iconButton("map") { NSWorkspace.shared.open(m) }
            }
        }
        .padding(.vertical, 2.5)
        .opacity(past && e.kind != .trip ? 0.6 : 1)
    }

    private func iconButton(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10)).foregroundStyle(Theme.info)
        }.buttonStyle(.plain)
    }

    private func icon(_ k: Kind) -> String {
        switch k {
        case .event:    return "circle.fill"
        case .trip:     return "tram.fill"
        case .reminder: return "checklist"
        case .leave:    return "figure.walk.departure"
        case .birthday: return "gift.fill"
        }
    }
    private func color(_ k: Kind) -> Color {
        switch k {
        case .event:    return Theme.info
        case .trip:     return Theme.accent
        case .reminder: return Theme.textDim
        case .leave:    return Theme.warn
        case .birthday: return Theme.info
        }
    }
}

/// Marges de départ par mode, réglables plus tard.
enum TripPlan {
    static func margin(_ mode: Trip.Mode) -> TimeInterval {
        switch mode {
        case .train: return 20 * 60
        case .flight: return 90 * 60
        case .bus:   return 15 * 60
        case .boat:  return 45 * 60
        }
    }
}
