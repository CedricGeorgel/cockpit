import Foundation
import Contacts
import Combine

struct Birthday: Identifiable {
    var id: String
    var name: String
    var date: Date        // prochaine occurrence
    var turning: Int?     // âge atteint, si l'année de naissance est connue
    var isToday: Bool { Calendar.current.isDateInToday(date) }
    var inDays: Int { Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: date).day ?? 0 }
}

/// Anniversaires des contacts, à ~3 semaines. Lecture seule.
final class BirthdaysModel: ObservableObject {
    @Published private(set) var upcoming: [Birthday] = []

    private var timer: Timer?

    func start() {
        refresh()
        // Une fois par jour suffit (et re-tente si l'accès Contacts arrive après coup).
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let store = CNContactStore()
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                        CNContactNicknameKey, CNContactBirthdayKey] as [CNKeyDescriptor]
            let req = CNContactFetchRequest(keysToFetch: keys)
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            var out: [Birthday] = []
            try? store.enumerateContacts(with: req) { c, _ in
                guard let b = c.birthday, let month = b.month, let day = b.day else { return }
                var comps = DateComponents(); comps.month = month; comps.day = day
                comps.year = cal.component(.year, from: today)
                guard var next = cal.date(from: comps) else { return }
                if cal.startOfDay(for: next) < today {
                    next = cal.date(byAdding: .year, value: 1, to: next) ?? next
                }
                let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: next)).day ?? 99
                guard days <= 21 else { return }
                let name = c.nickname.isEmpty
                    ? [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                    : c.nickname
                guard !name.isEmpty else { return }
                var turning: Int?
                if let y = b.year { turning = cal.component(.year, from: next) - y }
                out.append(Birthday(id: c.identifier, name: name,
                                    date: cal.date(bySettingHour: 9, minute: 0, second: 0, of: next) ?? next,
                                    turning: turning))
            }
            out.sort { $0.date < $1.date }
            DispatchQueue.main.async { self?.upcoming = out }
        }
    }
}
