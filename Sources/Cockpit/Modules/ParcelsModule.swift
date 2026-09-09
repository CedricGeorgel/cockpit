import SwiftUI
import AppKit

final class ParcelsModel: ObservableObject {
    @Published var parcels: [ParcelScanner.Parcel] = []
    @Published var loading = false
    @Published var error: String?
    @Published var lastSync: Date?

    private var timer: Timer?

    func start() {
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
                    self.parcels = list
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
                        detail: model.loading ? nil
                            : "Les mails de Colissimo, Chronopost, Mondial Relay, UPS, Amazon… apparaissent ici avec leur état.")
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
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 9))
            }.buttonStyle(.plain).foregroundStyle(Theme.textFaint)
        }
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
