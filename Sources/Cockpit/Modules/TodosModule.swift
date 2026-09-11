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
    /// Confirmation éphémère quand un rappel est créé pour un autre jour.
    @Published var lastAdded: String?

    private let store = EKEventStore()

    func start() {
        store.requestFullAccessToReminders { [weak self] ok, _ in
            DispatchQueue.main.async {
                self?.granted = ok
                if ok { self?.seedRulesIfNeeded() }
                self?.reload()
            }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                               queue: .main) { [weak self] _ in self?.reload() }
    }

    // MARK: - Classement automatique dans une liste Rappels

    /// `[calendarIdentifier: mots-clés]`. Édité par l'utilisateur (`RemindersRulesEditor`),
    /// gardé en local (les listes Rappels sont propres à ce Mac).
    @Published var rules: [String: [String]] = TodosModel.loadRules()
    private static let rulesKey = "cockpit.reminders.rules.v1"

    private static func loadRules() -> [String: [String]] {
        (UserDefaults.standard.dictionary(forKey: rulesKey) as? [String: [String]]) ?? [:]
    }

    func setRules(_ r: [String: [String]]) {
        var clean: [String: [String]] = [:]
        for (id, words) in r {
            var seen = Set<String>()
            let w = words.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            if !w.isEmpty { clean[id] = w }
        }
        rules = clean
        UserDefaults.standard.set(clean, forKey: Self.rulesKey)
        NotificationCenter.default.post(name: .cockpitLocalSettingChanged, object: nil)
    }

    func toggleRule(_ calendarId: String, _ word: String) {
        var r = rules
        var words = r[calendarId] ?? []
        if let i = words.firstIndex(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            words.remove(at: i)
        } else {
            words.append(word)
        }
        r[calendarId] = words
        setRules(r)
    }

    var reminderCalendars: [EKCalendar] {
        store.calendars(for: .reminder).filter(\.allowsContentModifications)
    }
    var defaultCalendarName: String {
        store.defaultCalendarForNewReminders()?.title ?? "la liste par défaut"
    }

    /// Suggestions de démarrage : rapprochées du **nom** de la liste (les identifiants
    /// ne sont connus qu'à l'exécution). Ne s'applique que si aucune règle n'existe
    /// encore — ensuite tout passe par l'éditeur, y compris pour des listes au nom
    /// qu'on ne peut pas deviner (ex. un surnom).
    private static let titleHints: [(match: String, keywords: [String])] = [
        ("sante",    ["rdv", "medecin", "docteur", "dentiste", "kine", "osteo", "psy",
                       "pharmacie", "ordonnance", "vaccin", "analyses"]),
        ("maison",   ["menage", "courses", "plomberie", "electricite", "loyer", "syndic",
                       "bricolage", "linge", "poubelles", "chauffage"]),
        ("voyage",   ["billet", "valise", "passeport", "hotel", "vol", "train", "visa",
                       "reservation", "itineraire"]),
        ("busines",  ["facture", "devis", "client", "contrat", "relance", "comptable",
                       "tva", "fournisseur", "invoice"]),
        ("animau",   ["veterinaire", "croquettes", "toilettage", "puces", "laisse", "pension"]),
        ("relation", ["anniversaire", "appeler", "cadeau", "diner", "visite", "famille"]),
        ("veille",   ["veille", "inspiration", "portfolio", "figma", "dribbble", "behance",
                       "typo", "tendance"]),
    ]

    private func seedRulesIfNeeded() {
        guard rules.isEmpty else { return }
        var seeded: [String: [String]] = [:]
        for c in reminderCalendars {
            let t = c.title.folding(options: .diacriticInsensitive, locale: nil).lowercased()
            if let hint = Self.titleHints.first(where: { t.contains($0.match) }) {
                seeded[c.calendarIdentifier] = hint.keywords
            }
        }
        guard !seeded.isEmpty else { return }
        setRules(seeded)
    }

    /// Première liste dont un mot-clé apparaît dans le titre du rappel (après
    /// retrait de la partie « date » par `DatePhrase`). Sinon la liste par défaut.
    private func bestCalendar(for title: String, fallback: EKCalendar) -> EKCalendar {
        let t = title.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        guard !t.isEmpty else { return fallback }
        for cal in reminderCalendars {
            guard let words = rules[cal.calendarIdentifier], !words.isEmpty else { continue }
            let hit = words.contains { w in
                let k = w.folding(options: .diacriticInsensitive, locale: nil).lowercased()
                return !k.isEmpty && t.contains(k)
            }
            if hit { return cal }
        }
        return fallback
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

    /// Ajoute un rappel. Comprend le langage naturel : « demain 9h appeler Paul »,
    /// « payer le loyer lundi », « dans 2h relancer »… Sinon échéance aujourd'hui.
    func addReminder(_ title: String) {
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard granted, !raw.isEmpty, let defaultCalendar = store.defaultCalendarForNewReminders() else { return }
        let p = DatePhrase.parse(raw)
        let cal = Calendar.current
        let r = EKReminder(eventStore: store)
        r.title = p.title
        r.calendar = bestCalendar(for: p.title, fallback: defaultCalendar)
        let due = p.due ?? Date()
        r.dueDateComponents = p.timed
            ? cal.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            : cal.dateComponents([.year, .month, .day], from: due)
        if p.timed {
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        try? store.save(r, commit: true)

        if let d = p.due, !Calendar.current.isDateInToday(d) {
            let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = p.timed ? "EEEE d MMM 'à' HH'h'mm" : "EEEE d MMM"
            lastAdded = "→ \(f.string(from: d))"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.lastAdded = nil }
        }
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
    @State private var showRules = false
    @FocusState private var addFocused: Bool

    var body: some View {
        ModuleBody {
            VStack(alignment: .leading, spacing: 8) {
                if !model.granted {
                    ModuleNotice(icon: "checklist", title: "Accès Rappels requis",
                                 action: ("Ouvrir les réglages", { model.openSettings() }))
                } else {
                    quickAdd
                    if let a = model.lastAdded {
                        Text(a).font(.ui(9.5, .medium)).foregroundStyle(Theme.accent)
                            .transition(.opacity)
                    }
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
            TextField("Rappel… (« demain 9h », « lundi »)", text: $newReminder)
                .textFieldStyle(.plain).font(.ui(12))
                .focused($addFocused)
                .onSubmit(submit)
            if !newReminder.isEmpty {
                Button("Ajouter", action: submit)
                    .buttonStyle(.plain).font(.ui(10, .semibold)).foregroundStyle(Theme.accent)
            }
            Button { showRules = true } label: {
                Image(systemName: "tag").font(.system(size: 10.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.rules.isEmpty ? Theme.textFaint : Theme.accent)
            .help("Classement automatique des rappels")
            .popover(isPresented: $showRules) { RemindersRulesEditor(model: model) }
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

/// Éditeur du classement automatique : un rappel ajouté depuis Cockpit part
/// dans la première liste Rappels dont un mot-clé apparaît dans son texte.
private struct RemindersRulesEditor: View {
    @ObservedObject var model: TodosModel
    @Environment(\.dismiss) private var dismiss
    @State private var custom: [String: String] = [:]   // calendarIdentifier → texte en cours

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Classement automatique")
            Text("Un rappel ajouté depuis Cockpit part dans la 1ʳᵉ liste ci-dessous dont un mot apparaît dans son texte. Sinon : \(model.defaultCalendarName).")
                .font(.ui(9.5)).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.reminderCalendars, id: \.calendarIdentifier) { cal in
                        listSection(cal)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(width: 300, height: 300)

            HStack {
                Spacer()
                Button("Fermer") { dismiss() }.buttonStyle(GhostButtonStyle(prominent: true))
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func listSection(_ cal: EKCalendar) -> some View {
        let id = cal.calendarIdentifier
        let words = model.rules[id] ?? []
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(Color(nsColor: cal.color ?? .systemGray)).frame(width: 7, height: 7)
                Text(cal.title).font(.ui(9.5, .semibold)).foregroundStyle(Theme.textDim)
            }
            if !words.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(words, id: \.self) { w in
                        Button { model.toggleRule(id, w) } label: {
                            Text(w).font(.ui(10))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.18)))
                                .foregroundStyle(Theme.text)
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("mot-clé…", text: Binding(
                    get: { custom[id] ?? "" },
                    set: { custom[id] = $0 }))
                    .textFieldStyle(.roundedBorder).font(.ui(10.5))
                    .onSubmit { addCustom(id) }
                Button("Ajouter") { addCustom(id) }
                    .buttonStyle(GhostButtonStyle())
                    .disabled((custom[id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addCustom(_ id: String) {
        let w = (custom[id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        model.toggleRule(id, w)
        custom[id] = ""
    }
}
