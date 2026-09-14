import SwiftUI

enum SubscriptionCycle: String, Codable, CaseIterable, Identifiable {
    case monthly, yearly
    var id: String { rawValue }
    var label: String { self == .monthly ? "mois" : "an" }
    /// Facteur pour ramener un montant à son équivalent mensuel.
    var monthlyFactor: Double { self == .monthly ? 1 : 1.0 / 12 }
}

struct Subscription: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var price: Double
    var cycle: SubscriptionCycle = .monthly
    var renewalDay: Int?
    /// Expéditeur d'origine si confirmé depuis un mail détecté — évite de le
    /// re-proposer plus tard.
    var senderAddress: String?
}

/// Mail repéré comme abonnement possible, pas encore confirmé.
struct SubscriptionCandidate: Identifiable, Equatable {
    var id: String   // identifiant du mail
    var senderAddress: String
    var name: String
    var price: Double?
    var subject: String
    var date: Date
}

/// Détection best-effort : sujet + expéditeur uniquement (Cockpit ne lit pas
/// le corps des mails). Beaucoup d'abonnements n'affichent pas leur prix dans
/// le sujet — la confirmation manuelle permet de le corriger.
enum SubscriptionDetector {
    static let keywords = [
        "abonnement", "réabonnement", "facture", "reçu", "renouvellement",
        "prélèvement", "confirmation de paiement", "paiement accepté", "paiement reçu",
        "subscription", "receipt", "invoice", "payment confirmation", "auto-renew",
    ]

    /// Repère un montant du style « 9,99 € », « 9.99€ », « €9.99 ».
    static func extractPrice(_ text: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: #"(\d+[.,]\d{2})\s?€|€\s?(\d+[.,]\d{2})"#) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            guard r.location != NSNotFound else { continue }
            if let v = Double(ns.substring(with: r).replacingOccurrences(of: ",", with: ".")) { return v }
        }
        return nil
    }
}

final class SubscriptionsStore: ObservableObject {
    @Published var items: [Subscription] { didSet { if !applying { persist() } } }
    @Published private(set) var dismissedSenders: Set<String> = SubscriptionsStore.loadDismissed()

    private static let key = "cockpit.subscriptions.v1"
    private static let dismissedKey = "cockpit.subscriptions.dismissed"
    private var applying = false

    init() {
        items = Self.decode()
        NotificationCenter.default.addObserver(
            forName: .cockpitSettingsImported, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let fresh = Self.decode()
            if fresh != self.items { self.applying = true; self.items = fresh; self.applying = false }
        }
    }

    private static func decode() -> [Subscription] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode([Subscription].self, from: data) else { return [] }
        return s
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
    private static func loadDismissed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
    }
    private func persistDismissed() {
        UserDefaults.standard.set(Array(dismissedSenders), forKey: Self.dismissedKey)
    }

    var monthlyTotal: Double { items.reduce(0) { $0 + $1.price * $1.cycle.monthlyFactor } }
    var yearlyTotal: Double { monthlyTotal * 12 }

    func add(name: String, price: Double, cycle: SubscriptionCycle, renewalDay: Int?, senderAddress: String? = nil) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        items.append(Subscription(name: n, price: price, cycle: cycle, renewalDay: renewalDay, senderAddress: senderAddress))
    }

    func update(_ id: Subscription.ID, name: String, price: Double, cycle: SubscriptionCycle, renewalDay: Int?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].name = name; items[i].price = price; items[i].cycle = cycle; items[i].renewalDay = renewalDay
    }

    func remove(_ id: Subscription.ID) { items.removeAll { $0.id == id } }

    /// Candidats détectés, un par expéditeur, hors abonnements déjà suivis ou écartés.
    func candidates(from mails: [MailModel.Mail]) -> [SubscriptionCandidate] {
        let excluded = dismissedSenders.union(items.compactMap(\.senderAddress))
        var seen = Set<String>()
        var out: [SubscriptionCandidate] = []
        for m in mails {
            let key = m.fromAddress.lowercased()
            guard !excluded.contains(key), seen.insert(key).inserted else { continue }
            let hay = (m.subject + " " + m.fromName).folding(options: .diacriticInsensitive, locale: nil).lowercased()
            guard SubscriptionDetector.keywords.contains(where: hay.contains) else { continue }
            out.append(SubscriptionCandidate(id: m.id, senderAddress: key, name: m.fromName,
                                             price: SubscriptionDetector.extractPrice(m.subject),
                                             subject: m.subject, date: m.date))
        }
        return out.sorted { $0.date > $1.date }
    }

    func confirm(_ c: SubscriptionCandidate) {
        add(name: c.name, price: c.price ?? 0, cycle: .monthly, renewalDay: nil, senderAddress: c.senderAddress)
    }
    func dismiss(_ c: SubscriptionCandidate) {
        guard dismissedSenders.insert(c.senderAddress).inserted else { return }
        persistDismissed()
    }
}

/// Suivi d'abonnements : détection best-effort dans les mails (sujet + prix),
/// confirmation manuelle, plus ajout direct. Total mensuel/annuel affiché.
struct SubscriptionsModule: View {
    @ObservedObject var store: SubscriptionsStore
    @ObservedObject var mail: MailModel
    @State private var showAdd = false
    @State private var editing: Subscription?

    private var candidates: [SubscriptionCandidate] {
        store.candidates(from: mail.sources.flatMap { mail.state($0.id).mails })
    }

    var body: some View {
        ModuleBody {
            VStack(alignment: .leading, spacing: 8) {
                header
                if candidates.isEmpty && store.items.isEmpty {
                    Text("Aucun abonnement suivi")
                        .font(.ui(11)).foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if !candidates.isEmpty {
                                SectionLabel(text: "Détectés dans les mails")
                                ForEach(candidates) { candidateRow($0) }
                            }
                            if !store.items.isEmpty {
                                if !candidates.isEmpty { SectionLabel(text: "Suivis").padding(.top, 4) }
                                ForEach(store.items) { row($0) }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAdd) { SubscriptionEditor(store: store, editing: nil) }
        .sheet(item: $editing) { sub in SubscriptionEditor(store: store, editing: sub) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.currency(store.monthlyTotal) + " / mois")
                    .font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                Text(Fmt.currency(store.yearlyTotal) + " / an")
                    .font(.ui(9.5)).foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Button { showAdd = true } label: {
                Image(systemName: "plus.circle").font(.system(size: 14))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .help("Ajouter un abonnement")
        }
    }

    private func candidateRow(_ c: SubscriptionCandidate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Theme.info).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(c.subject).font(.ui(9)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let p = c.price {
                Text(Fmt.currency(p)).font(.ui(10.5)).foregroundStyle(Theme.textDim)
            }
            Button { store.confirm(c) } label: {
                Image(systemName: "checkmark.circle").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .help("Confirmer — suivre cet abonnement")

            Button { store.dismiss(c) } label: {
                Image(systemName: "xmark.circle").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
            .help("Ignorer")
        }
        .padding(.vertical, 3)
    }

    private func row(_ s: Subscription) -> some View {
        Button { editing = s } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).font(.ui(12)).foregroundStyle(Theme.text).lineLimit(1)
                    if let day = s.renewalDay {
                        Text("renouvelle le \(day)").font(.ui(9)).foregroundStyle(Theme.textFaint)
                    }
                }
                Spacer(minLength: 4)
                Text(Fmt.currency(s.price) + " / " + s.cycle.label)
                    .font(.ui(10.5)).foregroundStyle(Theme.textDim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}

private struct SubscriptionEditor: View {
    @ObservedObject var store: SubscriptionsStore
    let editing: Subscription?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var priceText: String
    @State private var cycle: SubscriptionCycle
    @State private var renewalDay: String

    init(store: SubscriptionsStore, editing: Subscription?) {
        self.store = store
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _priceText = State(initialValue: editing.map { $0.price == 0 ? "" : String(format: "%.2f", $0.price) } ?? "")
        _cycle = State(initialValue: editing?.cycle ?? .monthly)
        _renewalDay = State(initialValue: editing?.renewalDay.map(String.init) ?? "")
    }

    private var price: Double? { Double(priceText.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: editing == nil ? "Nouvel abonnement" : "Modifier l'abonnement")

            TextField("Nom", text: $name).textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                TextField("Prix", text: $priceText).textFieldStyle(.roundedBorder).frame(width: 90)
                Picker("", selection: $cycle) {
                    ForEach(SubscriptionCycle.allCases) { c in Text("par " + c.label).tag(c) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                Spacer()
            }

            TextField("Jour de renouvellement (optionnel)", text: $renewalDay)
                .textFieldStyle(.roundedBorder)

            HStack {
                if editing != nil {
                    Button("Supprimer", role: .destructive) {
                        if let e = editing { store.remove(e.id) }
                        dismiss()
                    }
                    .buttonStyle(GhostButtonStyle())
                }
                Spacer()
                Button("Annuler") { dismiss() }.buttonStyle(GhostButtonStyle())
                Button(editing == nil ? "Ajouter" : "Enregistrer") { save() }
                    .buttonStyle(GhostButtonStyle(prominent: true))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || price == nil)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func save() {
        guard let p = price else { return }
        let day = Int(renewalDay)
        if let e = editing {
            store.update(e.id, name: name, price: p, cycle: cycle, renewalDay: day)
        } else {
            store.add(name: name, price: p, cycle: cycle, renewalDay: day)
        }
        dismiss()
    }
}
