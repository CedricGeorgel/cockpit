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
    var videoURL: URL? = nil   // lien visio détecté (Zoom/Meet/Teams…)
}

/// Repère un lien de visioconférence dans le texte d'un évènement.
enum MeetingLink {
    private static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com",
                                "teams.live.com", "whereby.com", "meet.jit.si",
                                "webex.com", "gotomeeting.com", "chime.aws", "around.co"]

    static func find(in parts: String?...) -> URL? {
        let hay = parts.compactMap { $0 }.joined(separator: " ")
        guard !hay.isEmpty else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(hay.startIndex..., in: hay)
        var candidates: [URL] = []
        detector?.enumerateMatches(in: hay, range: range) { m, _, _ in
            if let u = m?.url { candidates.append(u) }
        }
        return candidates.first { u in
            guard let host = u.host?.lowercased() else { return false }
            return hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
        }
    }
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
                           location: e.location?.isEmpty == false ? e.location : nil,
                           videoURL: MeetingLink.find(in: e.notes, e.location, e.url?.absoluteString))
            }
        DispatchQueue.main.async { self.events = evs }
    }
}

/// La carte « Agenda » a été fusionnée dans « Aujourd'hui » (TimelineModule) :
/// aujourd'hui + demain, sur une seule frise chronologique. `CalendarModel`
/// reste la source des évènements (frise, trajets, instantané).
