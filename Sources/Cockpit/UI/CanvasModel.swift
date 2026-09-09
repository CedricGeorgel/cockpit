import SwiftUI

/// Les modules disponibles. En ajouter un : un cas ici, sa fabrique dans
/// `ModuleHost`, et sa place par défaut dans `defaultColumns`.
enum ModuleKind: String, CaseIterable, Codable, Identifiable {
    case disk
    case timeline
    case calendar
    case weather
    case scratchpad
    case callTime
    case todos
    case news
    case nowPlaying
    case mail
    case battery
    case jobs
    case parcels
    case trips

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disk:       return "Disque & système"
        case .timeline:   return "Aujourd'hui"
        case .calendar:   return "Agenda"
        case .weather:    return "Météo"
        case .scratchpad: return "Bloc-notes"
        case .callTime:   return "Bon moment pour appeler"
        case .todos:      return "À faire aujourd'hui"
        case .news:       return "Actualités"
        case .nowPlaying: return "Lecture en cours"
        case .mail:       return "Mails importants"
        case .battery:    return "Batterie & appareils"
        case .jobs:       return "Suivi des candidatures"
        case .parcels:    return "Suivi de colis"
        case .trips:      return "Trajets"
        }
    }

    var icon: String {
        switch self {
        case .disk:       return "internaldrive"
        case .timeline:   return "calendar.day.timeline.left"
        case .calendar:   return "calendar"
        case .weather:    return "cloud.sun"
        case .scratchpad: return "note.text"
        case .callTime:   return "phone.arrow.up.right"
        case .todos:      return "checklist"
        case .news:       return "newspaper"
        case .nowPlaying: return "music.note"
        case .mail:       return "envelope"
        case .battery:    return "battery.100"
        case .jobs:       return "briefcase"
        case .parcels:    return "shippingbox"
        case .trips:      return "tram.fill"
        }
    }

    /// Poids de hauteur par défaut dans sa colonne.
    var defaultWeight: Double {
        switch self {
        case .timeline:   return 1.6
        case .weather:    return 1.0
        case .disk:       return 1.5
        case .nowPlaying: return 0.5
        case .calendar:   return 1.3
        case .todos:      return 1.2
        case .news:       return 1.8
        case .scratchpad: return 1.0
        case .callTime:   return 1.4
        case .mail:       return 1.6
        case .battery:    return 0.9
        case .jobs:       return 1.1
        case .parcels:    return 1.0
        case .trips:      return 0.8
        }
    }
}

/// Disposition en colonnes verticales. Chaque module occupe toute la largeur
/// de sa colonne ; sa hauteur est un poids relatif aux autres modules de la
/// même colonne (la colonne remplit toujours la fenêtre, jamais de
/// défilement). Plus de placement « entre deux colonnes ».
final class CanvasModel: ObservableObject {
    @Published private(set) var columns: [[ModuleKind]]
    @Published private(set) var weights: [ModuleKind: Double]
    @Published var columnCount: Int
    @Published var hidden: Set<ModuleKind>
    @Published var editing = false

    /// Manipulation en cours. On n'affiche PAS la carte qui suit le curseur,
    /// seulement le repère de l'endroit où elle se posera (façon Photoshop).
    @Published var draggingKind: ModuleKind?
    /// Point d'insertion visé : (colonne, index dans la colonne sans la carte tirée).
    @Published var drop: DropTarget?

    struct DropTarget: Equatable { var col: Int; var index: Int }

    static let minWeight = 0.4
    private static let key = "cockpit.columns.v1"

    struct Persisted: Codable {
        var columnCount: Int
        var columns: [[String]]
        var weights: [String: Double]
        var hidden: [String]
        var editing: Bool
        var weightsVersion: Int?
    }

    /// Incrémenté quand les poids par défaut changent : les cartes non
    /// retouchées reprennent la nouvelle valeur.
    private static let weightsVersion = 2

    init() {
        (columnCount, columns, weights, hidden, editing) = Self.decode()
        normalize()
        save()
        NotificationCenter.default.addObserver(
            forName: .cockpitSettingsImported, object: nil, queue: .main
        ) { [weak self] _ in self?.reloadFromDefaults() }
    }

    private static func decode() -> (Int, [[ModuleKind]], [ModuleKind: Double], Set<ModuleKind>, Bool) {
        guard let data = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return (3, defaultColumns, [:], [], false)
        }
        var w = Dictionary(uniqueKeysWithValues: p.weights.compactMap { key, v in
            ModuleKind(rawValue: key).map { ($0, v) }
        })
        if (p.weightsVersion ?? 1) < weightsVersion {
            w[.nowPlaying] = ModuleKind.nowPlaying.defaultWeight
        }
        return (min(max(2, p.columnCount), 4),
                p.columns.map { $0.compactMap(ModuleKind.init(rawValue:)) },
                w,
                Set(p.hidden.compactMap(ModuleKind.init(rawValue:))),
                p.editing)
    }

    /// Recharge la disposition depuis les préférences (après un import iCloud).
    func reloadFromDefaults() {
        let (cc, cols, w, h, _) = Self.decode()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            columnCount = cc
            columns = cols
            weights = w
            hidden = h
            normalize()
        }
    }

    // MARK: - Cohérence

    /// Répare la structure : bon nombre de colonnes, tout module visible
    /// présent exactement une fois, poids définis.
    private func normalize() {
        while columns.count < columnCount { columns.append([]) }
        if columns.count > columnCount {
            // Fusionne les colonnes en trop dans la dernière conservée.
            let extra = columns[columnCount...].flatMap { $0 }
            columns = Array(columns[..<columnCount])
            columns[columnCount - 1].append(contentsOf: extra)
        }
        // Dédoublonne et retire les masqués.
        var seen = Set<ModuleKind>()
        for c in columns.indices {
            columns[c] = columns[c].filter { k in
                guard !hidden.contains(k), !seen.contains(k) else { return false }
                seen.insert(k); return true
            }
        }
        // Ajoute les modules visibles absents, dans la colonne la plus courte.
        for k in ModuleKind.allCases where !hidden.contains(k) && !seen.contains(k) {
            shortestColumn().append(k, to: &columns)
            seen.insert(k)
        }
        for k in ModuleKind.allCases where weights[k] == nil {
            weights[k] = k.defaultWeight
        }
    }

    private func shortestColumn() -> Int {
        columns.indices.min { columns[$0].count < columns[$1].count } ?? 0
    }

    // MARK: - Lecture

    func weight(_ k: ModuleKind) -> Double {
        var w = weights[k] ?? k.defaultWeight
        // La météo réclame plus de hauteur quand son accordéon est ouvert, pour
        // ne pas déborder ; les cartes voisines de la colonne se resserrent.
        if k == .weather && Services.shared.weather.detailsOpen { w += 1.4 }
        return w
    }

    func columnWeight(_ col: Int) -> Double {
        guard columns.indices.contains(col) else { return 1 }
        return max(0.001, columns[col].reduce(0) { $0 + weight($1) })
    }

    var visibleKinds: [ModuleKind] { columns.flatMap { $0 } }

    // MARK: - Manipulation

    func beginDrag(_ k: ModuleKind) {
        draggingKind = k
        drop = currentPosition(of: k)
    }

    func setDrop(_ target: DropTarget) {
        if drop != target { drop = target }
    }

    func endDrag() {
        defer { draggingKind = nil; drop = nil }
        guard let k = draggingKind, let target = drop else { return }
        var next = columns
        for i in next.indices { next[i].removeAll { $0 == k } }
        guard next.indices.contains(target.col) else { return }
        let idx = min(max(0, target.index), next[target.col].count)
        next[target.col].insert(k, at: idx)
        guard next != columns else { return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { columns = next }
        save()
    }

    func cancelDrag() { draggingKind = nil; drop = nil }

    private func currentPosition(of k: ModuleKind) -> DropTarget {
        for (c, list) in columns.enumerated() {
            if let i = list.firstIndex(of: k) { return DropTarget(col: c, index: i) }
        }
        return DropTarget(col: 0, index: 0)
    }

    // Glissement d'un séparateur entre deux modules empilés.
    private var resizeSnapshot: (a: Double, b: Double)?

    func beginResize(col: Int, upper: Int) {
        guard let (a, b) = pair(col, upper) else { return }
        resizeSnapshot = (weight(a), weight(b))
    }

    /// `deltaWeight` = décalage total depuis le début du glissement.
    func updateResize(col: Int, upper: Int, deltaWeight: Double) {
        guard let snap = resizeSnapshot, let (a, b) = pair(col, upper) else { return }
        let d = max(-(snap.a - Self.minWeight), min(snap.b - Self.minWeight, deltaWeight))
        weights[a] = snap.a + d
        weights[b] = snap.b - d
    }

    func endResize() { resizeSnapshot = nil; save() }

    private func pair(_ col: Int, _ upper: Int) -> (ModuleKind, ModuleKind)? {
        guard columns.indices.contains(col), columns[col].indices.contains(upper + 1) else { return nil }
        return (columns[col][upper], columns[col][upper + 1])
    }

    func setColumnCount(_ n: Int) {
        let clamped = min(max(2, n), 4)
        guard clamped != columnCount else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            let growing = clamped > columnCount
            columnCount = clamped
            normalize()
            if growing { balance() }
        }
        save()
    }

    /// Comble les colonnes vides ou très courtes en prenant la carte du bas
    /// de la colonne la plus chargée.
    private func balance() {
        for _ in 0..<8 {
            guard let poor = columns.indices.min(by: { columnWeight($0) < columnWeight($1) }),
                  let rich = columns.indices.max(by: { columns[$0].count < columns[$1].count }),
                  poor != rich, columns[rich].count > 1,
                  columnWeight(poor) < columnWeight(rich) * 0.6,
                  let moved = columns[rich].popLast()
            else { return }
            columns[poor].insert(moved, at: 0)
        }
    }

    func toggleHidden(_ k: ModuleKind) {
        if hidden.contains(k) {
            hidden.remove(k)
        } else {
            hidden.insert(k)
            for i in columns.indices { columns[i].removeAll { $0 == k } }
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { normalize() }
        save()
    }

    func reset() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            columnCount = 3
            columns = Self.defaultColumns
            weights = Dictionary(uniqueKeysWithValues: ModuleKind.allCases.map { ($0, $0.defaultWeight) })
            hidden = []
            normalize()
        }
        save()
    }

    // MARK: - Persistance

    func save() {
        let p = Persisted(
            columnCount: columnCount,
            columns: columns.map { $0.map(\.rawValue) },
            weights: Dictionary(uniqueKeysWithValues: weights.map { ($0.key.rawValue, $0.value) }),
            hidden: hidden.map(\.rawValue),
            editing: editing,
            weightsVersion: Self.weightsVersion)
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static let defaultColumns: [[ModuleKind]] = [
        [.timeline, .weather, .disk, .nowPlaying, .battery],
        [.mail, .jobs, .calendar, .trips, .todos],
        [.news, .parcels, .scratchpad, .callTime],
    ]
}

private extension Int {
    /// Ajoute `k` à la colonne d'indice `self` de `columns`.
    func append(_ k: ModuleKind, to columns: inout [[ModuleKind]]) {
        guard columns.indices.contains(self) else { return }
        columns[self].append(k)
    }
}
