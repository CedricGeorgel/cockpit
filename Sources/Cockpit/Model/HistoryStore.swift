import Foundation

/// Un point par jour : dernières valeurs connues des modules dont la mesure
/// a du sens à cette granularité (pas la batterie, déjà suivie par macOS
/// lui-même ; pas la météo, qui n'a rien de personnel).
struct HistoryPoint: Codable {
    var date: String   // yyyy-MM-dd
    var diskUsedBytes: Int64?
    var diskTotalBytes: Int64?
    /// Part des habitudes cochées ce jour-là, 0-100.
    var habitsCompletionPercent: Int?
    var subscriptionsMonthlyTotal: Double?
    /// Mails importants reçus ce jour-là (cumulé au fil de la journée).
    var importantMailsToday: Int?
    /// Total cumulé de newsletters traitées/gardées (pas un delta du jour).
    var newslettersResolvedTotal: Int?
}

final class HistoryStore: ObservableObject {
    @Published private(set) var points: [HistoryPoint] = []

    private static let maxPoints = 400

    private static func fileURL(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cockpit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
    private static var url: URL { fileURL("history.json") }

    init() { points = Self.load() }

    private static func load() -> [HistoryPoint] {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode([HistoryPoint].self, from: data) else { return [] }
        return p
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// Met à jour le point du jour avec les dernières valeurs disponibles ;
    /// ne touche pas aux champs sans donnée pour l'instant (ex. abonnements
    /// pas encore configurés), pour ne pas écraser une valeur déjà connue.
    @MainActor
    func record() {
        let s = Services.shared
        let today = HabitsStore.dayKey(Date())
        var p = points.last(where: { $0.date == today }) ?? HistoryPoint(date: today)

        if s.disk.volumeTotal > 0 { p.diskUsedBytes = s.disk.volumeUsed; p.diskTotalBytes = s.disk.volumeTotal }
        if !s.habits.habits.isEmpty {
            let done = s.habits.habits.filter { $0.doneDays.contains(today) }.count
            p.habitsCompletionPercent = Int((Double(done) / Double(s.habits.habits.count) * 100).rounded())
        }
        if !s.subscriptions.items.isEmpty { p.subscriptionsMonthlyTotal = s.subscriptions.monthlyTotal }

        let cal = Calendar.current
        p.importantMailsToday = s.mail.sources
            .flatMap { s.mail.state($0.id).mails }
            .filter { cal.isDateInToday($0.date) }
            .count
        p.newslettersResolvedTotal = s.mail.resolvedSenders.count

        if let i = points.firstIndex(where: { $0.date == today }) {
            points[i] = p
        } else {
            points.append(p)
            if points.count > Self.maxPoints { points.removeFirst(points.count - Self.maxPoints) }
        }
        persist()
    }
}
