import SwiftUI
import AppKit

struct ManualParcel: Codable, Identifiable {
    var id = UUID().uuidString
    var number: String
    var carrier: String    // ParcelScanner.Carrier rawValue
    var label: String
    var addedAt = Date()
}

final class ParcelsModel: ObservableObject {
    @Published private(set) var parcels: [ParcelScanner.Parcel] = []
    @Published var loading = false
    @Published var error: String?
    @Published var lastSync: Date?
    @Published private(set) var manual: [ManualParcel] = ParcelsModel.loadManual()

    private var scanned: [ParcelScanner.Parcel] = []
    private var timer: Timer?

    private static let manualKey = "cockpit.parcels.manual.v1"
    private static func loadManual() -> [ManualParcel] {
        guard let d = UserDefaults.standard.data(forKey: manualKey),
              let l = try? JSONDecoder().decode([ManualParcel].self, from: d) else { return [] }
        return l
    }
    func addManual(number: String, label: String) {
        let n = number.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let car = ParcelScanner.Carrier.detect(n.lowercased())
        manual.append(ManualParcel(number: n, carrier: car.rawValue,
                                   label: label.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? "Colis \(car.display)" : label))
        persistManual(); rebuild()
    }
    func removeManual(_ id: String) {
        manual.removeAll { $0.id == id }; persistManual(); rebuild()
    }
    private func persistManual() {
        UserDefaults.standard.set(try? JSONEncoder().encode(manual), forKey: Self.manualKey)
    }

    private func rebuild() {
        let fromManual = manual.map { m -> ParcelScanner.Parcel in
            ParcelScanner.Parcel(
                id: "man-\(m.id)",
                carrier: ParcelScanner.Carrier(rawValue: m.carrier) ?? .other,
                number: m.number, status: .inTransit, date: m.addedAt,
                merchant: m.label, subject: "")
        }
        // Un colis suivi manuellement mais aussi repéré dans les mails : on garde le mail.
        let manualNums = Set(manual.map { $0.number.lowercased() })
        parcels = (scanned + fromManual.filter { p in
            !scanned.contains { ($0.number ?? "").lowercased() == (p.number ?? "").lowercased() && p.number != nil }
        })
        .filter { !($0.status == .delivered) || Date().timeIntervalSince($0.date) < 4 * 86400 }
        .sorted { $0.sortRank < $1.sortRank || ($0.sortRank == $1.sortRank && $0.date > $1.date) }
        _ = manualNums
    }

    func start() {
        rebuild()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let s = self.lastSync, Date().timeIntervalSince(s) > 600 else { return }
            self.refresh()
        }
    }

    func refresh() {
        guard AppleMailBridge.isMailInstalled, !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try ParcelScanner.scan() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let list):
                    self.scanned = list
                    self.rebuild()
                    self.error = nil
                    self.lastSync = Date()
                case .failure(let e):
                    self.error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
                }
            }
        }
    }
}

struct ParcelsModule: View {
    @ObservedObject var model: ParcelsModel
    @State private var showAdd = false
    @State private var num = ""
    @State private var label = ""

    var body: some View {
        ModuleBody {
            VStack(alignment: .leading, spacing: 8) {
                if let e = model.error, model.parcels.isEmpty {
                    ModuleNotice(icon: "shippingbox", title: "Suivi indisponible", detail: e,
                                 action: ("Réessayer", { model.refresh() }))
                } else if model.parcels.isEmpty {
                    ModuleNotice(
                        icon: "shippingbox",
                        title: model.loading ? "Recherche des colis…" : "Aucun colis en cours",
                        detail: model.loading ? nil : "Détectés dans tes mails, ou ajoutés à la main.",
                        action: ("Suivre un numéro", { showAdd = true }))
                        .popover(isPresented: $showAdd) { addPopover }
                } else {
                    header
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(model.parcels) { row($0) }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        let active = model.parcels.filter { $0.status != .delivered }.count
        return HStack(spacing: 6) {
            Text(active > 0 ? "\(active) en route" : "Tout est arrivé")
                .font(.ui(11, .semibold)).foregroundStyle(Theme.text)
            Spacer()
            if model.loading { ProgressView().controlSize(.mini).scaleEffect(0.7) }
            Button { showAdd = true } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
            }.buttonStyle(.plain).foregroundStyle(Theme.textFaint)
            .popover(isPresented: $showAdd) { addPopover }
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 9))
            }.buttonStyle(.plain).foregroundStyle(Theme.textFaint)
        }
    }

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Suivre un colis").font(.ui(11, .semibold)).foregroundStyle(Theme.text)
            TextField("Numéro de suivi", text: $num)
                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
            TextField("Nom (optionnel)", text: $label)
                .textFieldStyle(.roundedBorder).font(.ui(11))
            Text("Le transporteur est deviné d'après le numéro.")
                .font(.ui(9)).foregroundStyle(Theme.textFaint)
            HStack {
                Spacer()
                Button("Ajouter") {
                    model.addManual(number: num, label: label)
                    num = ""; label = ""; showAdd = false
                }
                .buttonStyle(GhostButtonStyle(prominent: true))
                .disabled(num.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12).frame(width: 240)
    }

    private func row(_ p: ParcelScanner.Parcel) -> some View {
        HStack(spacing: 9) {
            Image(systemName: p.status == .delivered ? "shippingbox" : "shippingbox.fill")
                .font(.system(size: 13))
                .foregroundStyle(color(p.status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.merchant).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(p.carrier.display)\(p.number.map { " · \($0)" } ?? "")")
                    .font(.ui(9)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(p.status.label)
                    .font(.ui(8.5, .semibold)).foregroundStyle(color(p.status))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(color(p.status).opacity(0.14)))
                Text(Fmt.relday(p.date)).font(.ui(8.5)).foregroundStyle(Theme.textFaint)
            }
            if let url = p.carrier.trackingURL(p.number) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.info)
                .help("Suivre chez \(p.carrier.display)")
            }
            if p.id.hasPrefix("man-") {
                Button { model.removeManual(String(p.id.dropFirst(4))) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }.buttonStyle(.plain).foregroundStyle(Theme.textFaint).help("Retirer")
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
        .opacity(p.status == .delivered ? 0.6 : 1)
    }

    private func color(_ s: ParcelScanner.Status) -> Color {
        switch s {
        case .issue:          return Theme.warn
        case .readyForPickup: return Theme.accent
        case .outForDelivery: return Theme.accent
        case .inTransit:      return Theme.info
        case .announced:      return Theme.textFaint
        case .delivered:      return Theme.textFaint
        }
    }
}
