import Foundation
import AppKit

/// Suit les versions publiées sur le serveur (`version.json` pour Cockpit,
/// `prisme-version.json` pour Prisme) et propose de télécharger la nouvelle.
/// Le DMG est récupéré via URLSession (pas de drapeau `com.apple.quarantine`),
/// donc plus d'avertissement Gatekeeper / de perte des autorisations disque à
/// chaque mise à jour.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum Kind: String { case cockpit, prisme
        var label: String { self == .cockpit ? "Cockpit" : "Prisme" }
        var feed: String  { self == .cockpit ? "version.json" : "prisme-version.json" }
        var dmgFallback: String { self == .cockpit ? "Cockpit.dmg" : "Prisme.dmg" }
    }

    struct Available: Equatable, Identifiable {
        var kind: Kind
        var version: String
        var url: URL
        var notes: String
        var id: String { kind.rawValue }
    }

    /// 0 à 2 bandeaux (Cockpit d'abord).
    @Published private(set) var available: [Available] = []
    @Published private(set) var downloading: Set<Kind> = []

    private let fallbackBase = "https://dashboard.caadesign.fr/"

    private var cockpitCurrent: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var timer: Timer?
    private var lastCheck = Date.distantPast
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        check(force: true)

        let t = Timer(timeInterval: 900, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.check() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.check(force: true) }
    }

    /// Base des feeds : dossier de `relay.php`, sinon le domaine canonique.
    private var feedBase: URL {
        let relay = RemoteBridge.shared.relayURLString
        if let r = URL(string: relay), let host = r.host {
            return URL(string: "\(r.scheme ?? "https")://\(host)\(r.deletingLastPathComponent().path)")
                ?? URL(string: fallbackBase)!
        }
        return URL(string: fallbackBase)!
    }

    func check(force: Bool = false) {
        if !force && Date().timeIntervalSince(lastCheck) < 60 { return }
        lastCheck = Date()
        checkOne(.cockpit)
        if PrismeAPI.installedVersion != nil { checkOne(.prisme) }
        else { drop(.prisme) }
    }

    private func checkOne(_ kind: Kind) {
        let feed = feedBase.appendingPathComponent(kind.feed)
        var req = URLRequest(url: feed)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let remote = obj["version"] as? String else { return }

            let local = kind == .cockpit ? self.cockpitCurrent : (PrismeAPI.installedVersion ?? "0")
            guard Self.isNewer(remote, than: local) else { self.drop(kind); return }

            let raw = (obj["url"] as? String) ?? kind.dmgFallback
            let link = URL(string: raw, relativeTo: feed)?.absoluteURL
                ?? URL(string: self.fallbackBase)!
            let entry = Available(kind: kind, version: remote, url: link,
                                  notes: obj["notes"] as? String ?? "")
            DispatchQueue.main.async {
                var list = self.available.filter { $0.kind != kind }
                list.append(entry)
                self.available = list.sorted { $0.kind == .cockpit && $1.kind != .cockpit }
            }
        }.resume()
    }

    private func drop(_ kind: Kind) {
        DispatchQueue.main.async {
            if self.available.contains(where: { $0.kind == kind }) {
                self.available.removeAll { $0.kind == kind }
            }
        }
    }

    /// Comparaison numérique champ par champ.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Téléchargement

    func openDownload(_ kind: Kind) {
        guard let a = available.first(where: { $0.kind == kind }), !downloading.contains(kind) else { return }
        downloading.insert(kind)

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cockpit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(kind.label)-\(a.version).dmg")

        let done = { DispatchQueue.main.async { self.downloading.remove(kind) } }
        let fallback = { DispatchQueue.main.async { self.downloading.remove(kind); NSWorkspace.shared.open(a.url) } }

        URLSession.shared.downloadTask(with: a.url) { tmp, resp, err in
            guard let tmp, err == nil,
                  (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true
            else { fallback(); return }
            try? FileManager.default.removeItem(at: dest)
            guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { fallback(); return }

            // Prisme : on peut remplacer l'app en place (pas quarantinée, exigence
            // désignée stable → les autorisations disque survivent) si elle ne tourne pas.
            if kind == .prisme, Self.tryReplacePrisme(fromDMG: dest) {
                done(); DispatchQueue.main.async { self.drop(.prisme) }
                return
            }
            DispatchQueue.main.async { NSWorkspace.shared.open(dest) }   // monte le DMG
            done()
        }.resume()
    }

    /// Monte le DMG, copie `Prisme.app` par-dessus l'installation existante,
    /// démonte. Renvoie false si Prisme tourne ou si quoi que ce soit échoue
    /// (on retombe alors sur « monter le DMG et laisser l'utilisateur glisser »).
    private static func tryReplacePrisme(fromDMG dmg: URL) -> Bool {
        guard let installed = PrismeAPI.appURL,
              FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path),
              NSRunningApplication.runningApplications(withBundleIdentifier: PrismeAPI.bundleID).isEmpty
        else { return false }

        let mnt = "/Volumes/Cockpit-Prisme-\(UUID().uuidString.prefix(6))"
        func sh(_ args: [String]) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = args
            try? p.run(); p.waitUntilExit()
            return p.terminationStatus == 0
        }
        guard sh(["attach", dmg.path, "-nobrowse", "-quiet", "-mountpoint", mnt]) else { return false }
        defer { _ = sh(["detach", mnt, "-quiet", "-force"]) }

        let src = URL(fileURLWithPath: mnt).appendingPathComponent("Prisme.app")
        guard FileManager.default.fileExists(atPath: src.path) else { return false }
        do {
            let tmp = installed.deletingLastPathComponent()
                .appendingPathComponent(".Prisme.old-\(UUID().uuidString.prefix(6)).app")
            try? FileManager.default.moveItem(at: installed, to: tmp)
            try FileManager.default.copyItem(at: src, to: installed)
            try? FileManager.default.removeItem(at: tmp)
            // Pas de quarantaine posée, mais on nettoie par sécurité.
            let x = Process()
            x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            x.arguments = ["-dr", "com.apple.quarantine", installed.path]
            try? x.run(); x.waitUntilExit()
            return true
        } catch { return false }
    }
}
