import SwiftUI
import AppKit
import EventKit

struct AgendaItem: Identifiable {
    let id: String
    let title: String
    let start: Date?
    let end: Date?
    let allDay: Bool
    let calendarColor: Color
    let location: String?
}

final class CalendarModel: ObservableObject {
    @Published var events: [AgendaItem] = []
    @Published var access: EventAccess = .unknown

    enum EventAccess { case unknown, granted, denied }

    private let store = EKEventStore()

    func start() {
        requestAccess()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: .EKEventStoreChanged, object: store)
    }

    @objc private func storeChanged() { reload() }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.access = granted ? .granted : .denied
                if granted { self?.reload() }
            }
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func reload() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 7, to: start)!

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let evs = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            .map { e in
                AgendaItem(id: e.eventIdentifier ?? UUID().uuidString,
                           title: e.title ?? "(sans titre)",
                           start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                           calendarColor: Color(nsColor: e.calendar.color ?? .systemGray),
                           location: e.location?.isEmpty == false ? e.location : nil)
            }
        DispatchQueue.main.async { self.events = evs }
    }
}

struct CalendarModule: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        ModuleBody {
            switch model.access {
            case .unknown:
                ModuleNotice(icon: "calendar", title: "Accès en attente…")
            case .denied:
                ModuleNotice(icon: "lock", title: "Accès Calendrier refusé",
                             detail: "Autorisez Cockpit dans Réglages Système › Confidentialité.",
                             action: ("Ouvrir les réglages", { model.openSettings() }))
            case .granted:
                content
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if model.events.isEmpty {
                    Text("Rien de prévu cette semaine.")
                        .font(.ui(11)).foregroundStyle(Theme.textFaint)
                        .padding(.top, 8)
                } else {
                    ForEach(grouped, id: \.0) { day, items in
                        SectionLabel(text: day).padding(.top, 6).padding(.bottom, 2)
                        ForEach(items) { row($0) }
                    }
                }
            }
        }
    }

    /// Événements groupés par jour (aujourd'hui, demain, puis date).
    private var grouped: [(String, [AgendaItem])] {
        let cal = Calendar.current
        var buckets: [(key: Date, label: String, items: [AgendaItem])] = []
        for item in model.events {
            let day = cal.startOfDay(for: item.start ?? Date())
            if let i = buckets.firstIndex(where: { $0.key == day }) {
                buckets[i].items.append(item)
            } else {
                buckets.append((day, Fmt.relday(item.start ?? Date()).capitalizedFirst, [item]))
            }
        }
        return buckets.map { ($0.label, $0.items) }
    }

    private func row(_ item: AgendaItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(item.calendarColor).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.ui(12, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(timeLabel(item))
                    .font(.ui(10))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func timeLabel(_ item: AgendaItem) -> String {
        guard let start = item.start else { return "" }
        if item.allDay { return "toute la journée" }
        var s = Fmt.shortTime(start)
        if let end = item.end { s += " à \(Fmt.shortTime(end))" }
        if let loc = item.location { s += " · \(loc)" }
        return s
    }
}
