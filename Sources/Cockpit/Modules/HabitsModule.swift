import SwiftUI

struct Habit: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// Jours cochés, au format "yyyy-MM-dd" (jour calendaire local).
    var doneDays: Set<String> = []
}

final class HabitsStore: ObservableObject {
    @Published var habits: [Habit] { didSet { if !applying { persist() } } }

    private static let key = "cockpit.habits.v1"
    private var applying = false

    init() {
        habits = Self.decode()
        NotificationCenter.default.addObserver(
            forName: .cockpitSettingsImported, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let fresh = Self.decode()
            if fresh != self.habits { self.applying = true; self.habits = fresh; self.applying = false }
        }
    }

    private static func decode() -> [Habit] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let h = try? JSONDecoder().decode([Habit].self, from: data) else { return [] }
        return h
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(habits) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        habits.append(Habit(name: trimmed))
    }

    func remove(_ id: Habit.ID) {
        habits.removeAll { $0.id == id }
    }

    func toggle(_ id: Habit.ID, day: Date) {
        guard let i = habits.firstIndex(where: { $0.id == id }) else { return }
        let key = Self.dayKey(day)
        if habits[i].doneDays.contains(key) { habits[i].doneDays.remove(key) }
        else { habits[i].doneDays.insert(key) }
    }

    /// Propositions prêtes à cocher, sur le principe des mots-clés de Mail.
    static let suggestions: [(String, [String])] = [
        ("Forme", ["Sport", "Marche", "Étirements", "Boire de l'eau"]),
        ("Bien-être", ["Méditation", "Lecture", "Coucher tôt", "Pas d'écran avant de dormir"]),
        ("Productivité", ["Faire le point du jour", "Vider la boîte mail", "Ranger le bureau"]),
        ("Perso", ["Appeler un proche", "Apprendre 15 min", "Cuisiner maison"]),
    ]

    func hasHabit(named name: String) -> Bool {
        habits.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func toggleSuggestion(_ name: String) {
        if let existing = habits.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            remove(existing.id)
        } else {
            add(name)
        }
    }

    /// Jours consécutifs cochés jusqu'à aujourd'hui (aujourd'hui non encore
    /// coché ne casse pas la série, pour laisser la journée se terminer).
    func streak(_ h: Habit) -> Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        if !h.doneDays.contains(Self.dayKey(day)) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while h.doneDays.contains(Self.dayKey(day)) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }
}

/// Suivi d'habitudes minimal : une liste, une grille des 7 derniers jours par
/// habitude, une série en cours. Coché du Mac ou de la PWA (le suivi vit dans
/// `Services`, poussé au relais comme les autres modules).
struct HabitsModule: View {
    @ObservedObject var store: HabitsStore
    @State private var newName = ""
    @State private var showSuggestions = false
    @FocusState private var addFocused: Bool

    private var lastDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
    }

    var body: some View {
        ModuleBody {
            VStack(alignment: .leading, spacing: 8) {
                quickAdd
                if store.habits.isEmpty {
                    Text("Aucune habitude suivie")
                        .font(.ui(11)).foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(store.habits) { row($0) }
                        }
                    }
                }
            }
        }
    }

    private var quickAdd: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
            TextField("Nouvelle habitude…", text: $newName)
                .textFieldStyle(.plain).font(.ui(12))
                .focused($addFocused)
                .onSubmit(submit)
            if !newName.isEmpty {
                Button("Ajouter", action: submit)
                    .buttonStyle(.plain).font(.ui(10, .semibold)).foregroundStyle(Theme.accent)
            }
            Button { showSuggestions = true } label: {
                Image(systemName: "tag").font(.system(size: 10.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.habits.isEmpty ? Theme.textFaint : Theme.accent)
            .help("Suggestions d'habitudes")
            .popover(isPresented: $showSuggestions) { HabitSuggestionsEditor(store: store) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func submit() {
        store.add(newName)
        newName = ""
        addFocused = true
    }

    private func row(_ h: Habit) -> some View {
        HStack(spacing: 8) {
            Text(h.name).font(.ui(12)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                ForEach(lastDays, id: \.self) { dayDot(h, $0) }
            }
            let streak = store.streak(h)
            if streak > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill").font(.system(size: 9))
                    Text("\(streak)").font(.ui(9.5, .semibold))
                }
                .foregroundStyle(Theme.warn)
                .frame(width: 26, alignment: .leading)
            } else {
                Color.clear.frame(width: 26)
            }
            Button { store.remove(h.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textFaint)
            }
            .buttonStyle(.plain)
            .opacity(0.5)
        }
        .padding(.vertical, 4)
    }

    private func dayDot(_ h: Habit, _ day: Date) -> some View {
        let done = h.doneDays.contains(HabitsStore.dayKey(day))
        let isToday = Calendar.current.isDateInToday(day)
        return Button { store.toggle(h.id, day: day) } label: {
            Circle()
                .fill(done ? Theme.accent : Color.primary.opacity(0.08))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(isToday ? Theme.accent : .clear, lineWidth: 1.4))
        }
        .buttonStyle(.plain)
        .help(Fmt.relday(day))
    }
}

/// Propositions d'habitudes courantes, sur le principe de l'éditeur de
/// mots-clés de Mail (chips groupées par thème, cochables).
private struct HabitSuggestionsEditor: View {
    @ObservedObject var store: HabitsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Suggestions d'habitudes")
            Text("Coche une suggestion pour l'ajouter à ton suivi ; décoche pour la retirer.")
                .font(.ui(9.5)).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(HabitsStore.suggestions, id: \.0) { section in
                        chipGroup(section.0, section.1)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(width: 280, height: 220)

            HStack {
                Spacer()
                Button("Fermer") { dismiss() }.buttonStyle(GhostButtonStyle(prominent: true))
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func chipGroup(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.ui(8.5, .semibold)).foregroundStyle(Theme.textFaint).tracking(0.4)
            FlowLayout(spacing: 5) {
                ForEach(names, id: \.self) { name in
                    Button { store.toggleSuggestion(name) } label: {
                        Text(name).font(.ui(10.5))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(store.hasHabit(named: name) ? Theme.accent.opacity(0.2) : Color.primary.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(store.hasHabit(named: name) ? Theme.accent.opacity(0.6) : Theme.hairline))
                            .foregroundStyle(store.hasHabit(named: name) ? Theme.text : Theme.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
