import SwiftUI
import AppKit

struct SystemPerf {
    var ramUsed: UInt64
    var ramTotal: UInt64
    var cpu: Double            // 0…100
    var thermal: String
}

struct FleetDisk: Identifiable {
    var id: String { name }
    var name: String
    var used: Int64
    var total: Int64
    var free: Int64
    var batteryPercent: Int?
    var batteryMinutes: Int?
}

final class DiskModel: ObservableObject {
    @Published var volumeUsed: Int64 = 0
    @Published var volumeTotal: Int64 = 0
    @Published var volumeFree: Int64 = 0
    @Published var volumeName = "Disque"
    @Published var perf: SystemPerf?
    @Published var fleet: [FleetDisk] = []

    private var timer: Timer?
    private var prevCPU: (total: Double, idle: Double)?

    func start() {
        refreshVolume()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(
            forName: .cockpitFleetUpdated, object: nil, queue: .main
        ) { [weak self] _ in self?.ingestFleet() }
    }

    private func ingestFleet() {
        let mine = RemoteBridge.shared.deviceID
        fleet = RemoteBridge.shared.fleet.compactMap { d in
            guard d.deviceId != mine, d.diskTotal > 0 else { return nil }
            return FleetDisk(name: d.name, used: d.diskUsed, total: d.diskTotal, free: d.diskFree,
                             batteryPercent: d.macPercent, batteryMinutes: d.macMinutesRemaining)
        }
    }

    /// Compat : appelé par un timer plus lent dans Services.
    func refreshVolume() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
            volumeTotal = Int64(v.volumeTotalCapacity ?? 0)
            volumeFree = v.volumeAvailableCapacityForImportantUsage ?? 0
            volumeUsed = max(0, volumeTotal - volumeFree)
            volumeName = v.volumeName ?? "Disque"
        }
    }

    private func tick() {
        let mem = SystemMetrics.memory()
        var cpu = perf?.cpu ?? 0
        if let now = SystemMetrics.cpuTicks() {
            if let prev = prevCPU {
                let dt = now.total - prev.total, di = now.idle - prev.idle
                if dt > 0 { cpu = max(0, min(100, (1 - di / dt) * 100)) }
            }
            prevCPU = now
        }
        perf = SystemPerf(ramUsed: mem.used, ramTotal: mem.total, cpu: cpu, thermal: SystemMetrics.thermalLabel)
    }
}

// MARK: - Vue

struct DiskModule: View {
    @ObservedObject var model: DiskModel

    var body: some View {
        ModuleBody {
            VStack(alignment: .leading, spacing: 10) {
                diskBar("Ce Mac", model.volumeUsed, model.volumeTotal, model.volumeFree)
                ForEach(model.fleet) { f in
                    diskBar(f.name, f.used, f.total, f.free,
                            battery: f.batteryMinutes.map { "\(dur($0)) d'autonomie" }
                                ?? f.batteryPercent.map { "batterie \($0) %" })
                }
                if let p = model.perf {
                    Divider().overlay(Theme.hairline)
                    metric("Mémoire", ramText(p),
                           ratio: p.ramTotal > 0 ? Double(p.ramUsed) / Double(p.ramTotal) : 0)
                    metric("Processeur", "\(Int(p.cpu.rounded())) %", ratio: p.cpu / 100)
                    HStack(spacing: 8) {
                        Text("Température").font(.ui(11)).foregroundStyle(Theme.textDim)
                        Spacer()
                        Text(p.thermal).font(.num(11.5, .medium))
                            .foregroundStyle(p.thermal == "normale" ? Theme.accent
                                             : p.thermal == "modérée" ? Theme.info : Theme.warn)
                    }
                }
                Spacer(minLength: 0)
                prismeButton
            }
        }
    }

    @ViewBuilder private var prismeButton: some View {
        let installed = PrismeAPI.isAvailable
        Button {
            if installed { PrismeAPI.openApp() }
            else { NSWorkspace.shared.open(PrismeAPI.siteURL) }
        } label: {
            Label(installed ? "Analyser avec Prisme" : "Installer Prisme",
                  systemImage: installed ? "chart.pie.fill" : "arrow.down.circle")
                .font(.ui(10.5, .medium))
                .foregroundStyle(Theme.info)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func diskBar(_ name: String, _ used: Int64, _ total: Int64, _ free: Int64,
                         battery: String? = nil) -> some View {
        let ratio = total > 0 ? Double(used) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive.fill").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                Text(name).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                if total > 0 {
                    Text("\(pct(ratio)) %").font(.num(11, .semibold))
                        .foregroundStyle(ratio > 0.9 ? Theme.warn : Theme.accent).monospacedDigit()
                }
            }
            bar(ratio, ratio > 0.9 ? Theme.warn : ratio > 0.75 ? Theme.info : Theme.accent)
            if total > 0 {
                Text("\(Fmt.bytes(used)) sur \(Fmt.bytes(total)), \(Fmt.bytes(free)) libres"
                     + (battery.map { " · \($0)" } ?? ""))
                    .font(.ui(10)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
        }
    }

    private func metric(_ label: String, _ value: String, ratio: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.ui(11)).foregroundStyle(Theme.textDim)
                Spacer()
                Text(value).font(.num(11.5, .medium)).foregroundStyle(Theme.text).monospacedDigit()
            }
            bar(ratio, ratio > 0.85 ? Theme.warn : ratio > 0.6 ? Theme.info : Theme.accent)
        }
    }

    private func bar(_ ratio: Double, _ color: Color) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(3, g.size.width * min(1, max(0, ratio))))
            }
        }
        .frame(height: 6)
    }

    private func ramText(_ p: SystemPerf) -> String {
        "\(Fmt.bytes(Int64(p.ramUsed))) sur \(Fmt.bytes(Int64(p.ramTotal)))"
    }
    private func pct(_ r: Double) -> Int { Int((r * 100).rounded()) }
    private func dur(_ m: Int) -> String { m < 60 ? "\(m) min" : "\(m / 60) h\(m % 60 == 0 ? "" : String(format: " %02d", m % 60))" }
}
