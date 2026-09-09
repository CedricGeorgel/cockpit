import SwiftUI
import AppKit
import EventKit

struct TodoItem: Identifiable {
    let id: String
    var title: String
    var overdue: Bool
    var due: Date?
}

final class TodosModel: ObservableObject {
    @Published var items: [TodoItem] = []
    @Published var granted = false

    private let store = EKEventStore()

    func start() {
        store.requestFullAccessToReminders { [weak self] ok, _ in
            DispatchQueue.main.async { self?.granted = ok; self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                               queue: .main) { [weak self] _ in self?.reload() }
    }

    func reload() {
        guard granted else { items = []; return }
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date())!
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                         ending: endOfDay, calendars: nil)
        store.fetchReminders(matching: pred) { [weak self] rems in
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let hasTime = { (r: EKReminder) in r.dueDateComponents?.hour != nil }
            let list = (rems ?? []).map { r -> TodoItem in
                let due = r.dueDateComponents?.date
                let overdue: Bool = {
                    guard let due else { return false }
                    return hasTime(r) ? due < Date() : cal.startOfDay(for: due) < today
                }()
                return TodoItem(id: r.calendarItemIdentifier,
                                title: r.title ?? "(sans titre)",
                                overdue: overdue, due: hasTime(r) ? due : nil)
            }
            .sorted { lhs, rhs in
                if lhs.overdue != rhs.overdue { return lhs.overdue }
                return (lhs.due ?? .distantFuture) < (rhs.due ?? .distantFuture)
            }
            DispatchQueue.main.async { self?.items = list }
        }
    }

    func complete(_ id: String) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        r.isCompleted = true
        try? store.save(r, commit: true)
        reload()
    }

    /// Ajoute un rappel, échéance aujourd'hui, dans la liste par défaut.
    func addReminder(_ title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard granted, !text.isEmpty, let calendar = store.defaultCalendarForNewReminders() else { return }
        let r = EKReminder(eventStore: store)
        r.title = text
        r.calendar = calendar
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        try? store.save(r, commit: true)
        reload()
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct TodosModule: View {
    @ObservedObject var model: TodosModel
    @State private var newReminder = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        ModuleBody {
            VStack(alignment: .leading, spacing: 8) {
                if !model.granted {
                    ModuleNotice(icon: "checklist", title: "Accès Rappels requis",
                                 action: ("Ouvrir les réglages", { model.openSettings() }))
                } else {
                    quickAdd
                    if model.items.isEmpty {
                        Text("Rien à faire aujourd'hui")
                            .font(.ui(11)).foregroundStyle(Theme.textFaint)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(model.items) { row($0) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var quickAdd: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
            TextField("Ajouter un rappel pour aujourd'hui…", text: $newReminder)
                .textFieldStyle(.plain).font(.ui(12))
                .focused($addFocused)
                .onSubmit(submit)
            if !newReminder.isEmpty {
                Button("Ajouter", action: submit)
                    .buttonStyle(.plain).font(.ui(10, .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func submit() {
        model.addReminder(newReminder)
        newReminder = ""
        addFocused = true
    }

    private func row(_ item: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { model.complete(item.id) } label: {
                Image(systemName: "circle")
                    .font(.system(size: 13)).foregroundStyle(Theme.textFaint)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.ui(12)).foregroundStyle(Theme.text).lineLimit(2)
                if item.overdue {
                    Text("en retard").font(.ui(9.5)).foregroundStyle(Theme.warn)
                } else if let d = item.due {
                    Text(Fmt.shortTime(d)).font(.ui(9.5)).foregroundStyle(Theme.textFaint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}
