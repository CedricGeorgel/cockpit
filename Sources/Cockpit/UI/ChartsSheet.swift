import SwiftUI
import Charts

/// Historique des données mesurées (disque, habitudes, abonnements, mails),
/// un point par jour, construit en tâche de fond par `HistoryStore`.
struct ChartsSheet: View {
    @ObservedObject var history: HistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var metric: Metric = .disk

    enum Metric: String, CaseIterable, Identifiable {
        case disk, habits, subscriptions, mails, newsletters
        var id: String { rawValue }
        var title: String {
            switch self {
            case .disk:          return "Disque"
            case .habits:        return "Habitudes"
            case .subscriptions: return "Abonnements"
            case .mails:         return "Mails importants"
            case .newsletters:   return "Newsletters traitées"
            }
        }
        var unit: String {
            switch self {
            case .disk:          return "Go"
            case .habits:        return "%"
            case .subscriptions: return "€/mois"
            case .mails:         return "mails/j"
            case .newsletters:   return "total"
            }
        }
    }

    private struct Point: Identifiable { var id = UUID(); var date: Date; var value: Double }

    private var points: [Point] {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return history.points.compactMap { p -> Point? in
            guard let d = f.date(from: p.date) else { return nil }
            let v: Double?
            switch metric {
            case .disk:          v = p.diskUsedBytes.map { Double($0) / 1_073_741_824 }
            case .habits:        v = p.habitsCompletionPercent.map(Double.init)
            case .subscriptions: v = p.subscriptionsMonthlyTotal
            case .mails:         v = p.importantMailsToday.map(Double.init)
            case .newsletters:   v = p.newslettersResolvedTotal.map(Double.init)
            }
            guard let val = v else { return nil }
            return Point(date: d, value: val)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 16)).foregroundStyle(Theme.accent)
                Text("Historique").font(.ui(16, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textFaint)
                }.buttonStyle(.plain)
            }

            Picker("", selection: $metric) {
                ForEach(Metric.allCases) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented).labelsHidden()

            if points.count < 2 {
                ModuleNotice(icon: "chart.xyaxis.line", title: "Pas encore assez de données",
                             detail: "Un point par jour ; reviens dans quelques jours.")
                    .frame(height: 340)
            } else {
                Chart(points) { p in
                    LineMark(x: .value("Jour", p.date, unit: .day), y: .value(metric.title, p.value))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Jour", p.date, unit: .day), y: .value(metric.title, p.value))
                        .foregroundStyle(Theme.accent)
                }
                .chartYAxisLabel(metric.unit)
                .frame(height: 340)
            }
        }
        .padding(24)
        .frame(width: 680)
    }
}
