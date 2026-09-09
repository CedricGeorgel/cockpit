import SwiftUI
import IOKit
import IOKit.ps

struct MacBattery {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    var minutesRemaining: Int?     // vers vide, ou vers plein si en charge
    var cycleCount: Int?
    var healthPercent: Int?        // capacité max / capacité de conception
}

struct DeviceBattery: Identifiable {
    var id: String { name }
    var name: String
    var icon: String
    var percent: Int
    var extra: String?             // « boîtier 80 % », « G 45 % · D 47 % »
    var lastSeen: Date?            // horodatage de la lecture (toujours renseigné pour un appareil vu)
    var isLive = true              // vu lors du dernier scan (sinon : valeur mémorisée)
    var viaDevice: String?         // Mac de la flotte qui a fourni la lecture
}

struct FleetMacBattery: Identifiable {
    var id: String { name }
    var name: String
    var percent: Int
    var charging: Bool
    var minutesRemaining: Int?
}

final class BatteryModel: ObservableObject {
    @Published var mac: MacBattery?
    @Published var localDevices: [DeviceBattery] = []
    @Published var fleetMacs: [FleetMacBattery] = []
    @Published var fleetDevices: [DeviceBattery] = []

    private var timer: Timer?

    /// Appareils BT fusionnés (local + flotte), lecture la plus récente par appareil.
    var devices: [DeviceBattery] {
        var by: [String: DeviceBattery] = [:]
        for d in localDevices + fleetDevices {
            if let e = by[d.name], (e.lastSeen ?? .distantPast) >= (d.lastSeen ?? .distantPast) { continue }
            by[d.name] = d
        }
        return by.values.sorted { ($0.isLive ? 0 : 1, $0.percent) < ($1.isLive ? 0 : 1, $1.percent) }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(
            forName: .cockpitFleetUpdated, object: nil, queue: .main
        ) { [weak self] _ in self?.ingestFleet() }
    }

    private func ingestFleet() {
        let mine = RemoteBridge.shared.deviceID
        var macs: [FleetMacBattery] = []
        var devs: [DeviceBattery] = []
        for d in RemoteBridge.shared.fleet where d.deviceId != mine {
            if let p = d.macPercent {
                macs.append(.init(name: d.name, percent: p, charging: d.macCharging,
                                  minutesRemaining: d.macMinutesRemaining))
            }
            for b in d.btDevices {
                devs.append(DeviceBattery(name: b.name, icon: b.icon, percent: b.percent, extra: b.extra,
                                          lastSeen: b.lastSeen ?? d.pushedAt,
                                          isLive: b.lastSeen == nil, viaDevice: d.name))
            }
        }
        fleetMacs = macs
        fleetDevices = devs
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let mac = Self.readMac()
            let devices = Self.readBluetooth()
            DispatchQueue.main.async {
                self?.mac = mac
                self?.localDevices = devices
            }
        }
    }

    // MARK: Batterie du Mac

    private static func readMac() -> MacBattery? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let desc = sources
                .compactMap({ IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any] })
                .first(where: { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType })
        else { return macFromRegistry() }

        let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
        let state = desc[kIOPSPowerSourceStateKey] as? String
        let plugged = state == kIOPSACPowerValue
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let toEmpty = desc[kIOPSTimeToEmptyKey] as? Int ?? -1
        let toFull = desc[kIOPSTimeToFullChargeKey] as? Int ?? -1
        let mins = charging ? (toFull > 0 ? toFull : nil) : (toEmpty > 0 ? toEmpty : nil)

        var battery = MacBattery(percent: percent, charging: charging, pluggedIn: plugged,
                                 minutesRemaining: mins, cycleCount: nil, healthPercent: nil)
        if let reg = registryValues() {
            battery.cycleCount = reg.cycles
            battery.healthPercent = reg.health
        }
        return battery
    }

    private static func macFromRegistry() -> MacBattery? {
        // Sur un Mac de bureau il n'y a pas de batterie interne : on n'affiche
        // « Ce Mac » que si le registre expose un compteur de cycles crédible.
        guard let reg = registryValues(), let cycles = reg.cycles, cycles > 0 else { return nil }
        return MacBattery(percent: reg.percent, charging: reg.charging, pluggedIn: reg.charging,
                          minutesRemaining: nil, cycleCount: cycles, healthPercent: reg.health)
    }

    private static func registryValues()
        -> (percent: Int, charging: Bool, cycles: Int?, health: Int?)? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int)
        }
        func bool(_ key: String) -> Bool? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool)
        }
        let cur = int("CurrentCapacity") ?? 0
        let maxc = int("MaxCapacity") ?? 100
        let percent = maxc > 0 ? Int((Double(cur) / Double(maxc) * 100).rounded()) : cur
        let cycles = int("CycleCount")
        var health: Int?
        if let rawMax = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity"),
           let design = int("DesignCapacity"), design > 0 {
            health = Int((Double(rawMax) / Double(design) * 100).rounded())
        }
        return (percent, bool("IsCharging") ?? false, cycles, health)
    }

    // MARK: Appareils Bluetooth

    // Mémoire des derniers niveaux connus : si les AirPods sont partis, on garde
    // « 42 % · vu 13:42 » un moment plutôt que de faire disparaître la ligne.
    private struct StoredDevice: Codable { var icon: String; var percent: Int; var extra: String?; var at: Date }
    private static let storeKey = "cockpit.battery.devices.v1"
    private static func loadStore() -> [String: StoredDevice] {
        (UserDefaults.standard.data(forKey: storeKey))
            .flatMap { try? JSONDecoder().decode([String: StoredDevice].self, from: $0) } ?? [:]
    }
    private static func saveStore(_ s: [String: StoredDevice]) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: storeKey) }
    }

    private static func readBluetooth() -> [DeviceBattery] {
        var live: [DeviceBattery] = []
        var seen = Set<String>()

        // 1. Périphériques HID Apple (trackpad, souris, clavier) via IORegistry.
        if let dump = Shell.run("/usr/sbin/ioreg", ["-r", "-k", "BatteryPercent"]) {
            var name: String?
            for raw in dump.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if let r = line.range(of: "\"Product\" = \"") {
                    name = String(line[r.upperBound...].dropLast())
                } else if line.hasPrefix("\"BatteryPercent\" ="), let n = name,
                          let pct = Int(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") {
                    let clean = tidy(n)
                    if seen.insert(clean.lowercased()).inserted {
                        live.append(DeviceBattery(name: clean, icon: iconName(n), percent: pct, extra: nil))
                    }
                    name = nil
                }
            }
        }

        // 2. Casques / AirPods connectés via system_profiler.
        if let json = Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 20),
           let data = json.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = root["SPBluetoothDataType"] as? [[String: Any]] {
            for block in arr {
                guard let list = block["device_connected"] as? [[String: [String: Any]]] else { continue }
                for entry in list {
                    for (name, props) in entry {
                        guard let d = headset(name: name, props: props),
                              seen.insert(d.name.lowercased()).inserted else { continue }
                        live.append(d)
                    }
                }
            }
        }

        // Fusion avec la mémoire.
        let now = Date()
        var store = loadStore()
        for d in live {
            store[d.name] = StoredDevice(icon: d.icon, percent: d.percent, extra: d.extra, at: now)
        }
        store = store.filter { now.timeIntervalSince($0.value.at) < 24 * 3600 }   // oubli après 24 h
        saveStore(store)

        let liveNames = Set(live.map(\.name))
        return store.map { name, s in
            DeviceBattery(name: name, icon: s.icon, percent: s.percent, extra: s.extra,
                          lastSeen: s.at, isLive: liveNames.contains(name))
        }
        .sorted { ($0.isLive ? 0 : 1, $0.percent) < ($1.isLive ? 0 : 1, $1.percent) }
    }

    private static func headset(name: String, props: [String: Any]) -> DeviceBattery? {
        func pct(_ v: Any?) -> Int? {
            guard let s = v as? String else { return nil }
            let digits = s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            return Int(String(String.UnicodeScalarView(digits)))
        }
        let main = pct(props["device_batteryLevelMain"])
        let left = pct(props["device_batteryLevelLeft"])
        let right = pct(props["device_batteryLevelRight"])
        let caseP = pct(props["device_batteryLevelCase"])
        let clean = tidy(name)

        if let l = left, let r = right {
            var extra = "G \(l) % · D \(r) %"
            if let c = caseP { extra += " · boîtier \(c) %" }
            return DeviceBattery(name: clean, icon: iconName(name), percent: min(l, r), extra: extra)
        }
        if let m = main ?? left ?? right {
            return DeviceBattery(name: clean, icon: iconName(name), percent: m,
                                 extra: caseP.map { "boîtier \($0) %" })
        }
        return nil
    }

    /// Retire les suffixes personnels (« Magic Trackpad de Cedric »).
    private static func tidy(_ name: String) -> String {
        if let r = name.range(of: " de ", options: .backwards) {
            let tail = name[r.upperBound...]
            if tail.split(separator: " ").count == 1 { return String(name[..<r.lowerBound]) }
        }
        return name
    }

    private static func iconName(_ name: String) -> String {
        let l = name.lowercased()
        if l.contains("airpod") || l.contains("beats") || l.contains("buds") || l.contains("casque") { return "airpodspro" }
        if l.contains("mouse") || l.contains("souris") { return "magicmouse" }
        if l.contains("keyboard") || l.contains("clavier") { return "keyboard" }
        if l.contains("trackpad") { return "trackpad" }
        if l.contains("controller") || l.contains("manette") || l.contains("dualsense") || l.contains("xbox") { return "gamecontroller" }
        return "dot.radiowaves.right"
    }
}

// MARK: - Vue

struct BatteryModule: View {
    @ObservedObject var model: BatteryModel

    private var isEmpty: Bool {
        model.mac == nil && model.devices.isEmpty && model.fleetMacs.isEmpty
    }

    var body: some View {
        ModuleBody {
            VStack(alignment: .leading, spacing: 9) {
                if let m = model.mac { macRow("Ce Mac", m.percent, m.charging, m.minutesRemaining,
                                             cycles: m.cycleCount, health: m.healthPercent, plugged: m.pluggedIn) }
                ForEach(model.fleetMacs) { fm in
                    macRow(fm.name, fm.percent, fm.charging, fm.minutesRemaining)
                }
                if !model.devices.isEmpty {
                    if model.mac != nil || !model.fleetMacs.isEmpty { Divider().overlay(Theme.hairline) }
                    ForEach(model.devices) { deviceRow($0) }
                }
                if isEmpty {
                    ModuleNotice(icon: "battery.50", title: "Batterie indisponible")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func macRow(_ name: String, _ percent: Int, _ charging: Bool, _ mins: Int?,
                        cycles: Int? = nil, health: Int? = nil, plugged: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: charging ? "battery.100.bolt" : batterySymbol(percent))
                    .font(.system(size: 13)).foregroundStyle(color(percent))
                Text(name).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Text("\(percent) %").font(.num(13, .semibold)).foregroundStyle(color(percent)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color(percent)).frame(width: max(3, g.size.width * Double(percent) / 100))
                }
            }
            .frame(height: 6)
            HStack(spacing: 8) {
                if let mins {
                    Text(charging ? "plein dans \(dur(mins))" : "\(dur(mins)) d'autonomie")
                } else if plugged {
                    Text(charging ? "en charge" : "sur secteur")
                }
                if let cycles { Text("· \(cycles) cycles") }
                if let health { Text("· santé \(health) %") }
            }
            .font(.ui(9.5)).foregroundStyle(Theme.textFaint)
        }
    }

    private func deviceRow(_ d: DeviceBattery) -> some View {
        HStack(spacing: 8) {
            Image(systemName: d.icon).font(.system(size: 11)).foregroundStyle(Theme.textFaint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.name).font(.ui(11.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle(d)).font(.ui(9)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(d.percent) %").font(.num(11.5, .medium))
                .foregroundStyle(d.isLive ? color(d.percent) : Theme.textFaint)
                .monospacedDigit()
        }
        .opacity(d.isLive ? 1 : 0.6)
    }

    private func subtitle(_ d: DeviceBattery) -> String {
        var parts: [String] = []
        if d.isLive, let e = d.extra { parts.append(e) }
        if let seen = d.lastSeen { parts.append((d.isLive ? "maj " : "vu ") + Fmt.shortTime(seen)) }
        if let via = d.viaDevice { parts.append("via \(via)") }
        return parts.joined(separator: " · ")
    }

    private func color(_ p: Int) -> Color {
        switch p {
        case ..<15: return Theme.warn
        case ..<30: return Theme.info
        default:    return Theme.accent
        }
    }
    private func batterySymbol(_ p: Int) -> String {
        switch p {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<65: return "battery.50"
        case ..<90: return "battery.75"
        default:    return "battery.100"
        }
    }
    private func dur(_ m: Int) -> String {
        m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60 == 0 ? "" : "\(m % 60)")".trimmingCharacters(in: .whitespaces)
    }
}
