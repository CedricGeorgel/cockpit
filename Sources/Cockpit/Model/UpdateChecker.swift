import Foundation
import AppKit

/// Vérifie s'il existe une version plus récente publiée sur le serveur
/// (`version.json` à côté de la PWA). Purement informatif : propose le
/// téléchargement du DMG, n'installe rien.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Available: Equatable {
        var version: String
        var url: URL
        var notes: String
    }

    @Published private(set) var available: Available?

    /// Feed canonique si le pont n'est pas encore configuré.
    private let fallbackBase = "https://dashboard.caadesign.fr/"

    private var current: String {
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

        // Vérif périodique (l'app tourne souvent en fond : on veut la voir arriver
        // sans relancer). 15 min, c'est ~100 octets de texte.
        let t = Timer(timeInterval: 900, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // …et sur les évènements qui « réveillent » l'app.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.check() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.check(force: true) }
    }

    /// URL de `version.json` : dérivée de l'adresse du relais, sinon le feed canonique.
    private var feedURL: URL? {
        let relay = RemoteBridge.shared.relayURLString
        let base: String
        if let r = URL(string: relay), let host = r.host {
            base = "\(r.scheme ?? "https")://\(host)\(r.deletingLastPathComponent().path)"
        } else {
            base = fallbackBase
        }
        let joined = base.hasSuffix("/") ? base + "version.json" : base + "/version.json"
        return URL(string: joined)
    }

    func check(force: Bool = false) {
        // Anti-rafale : au plus une requête par minute (sauf réveil / lancement).
        if !force && Date().timeIntervalSince(lastCheck) < 60 { return }
        lastCheck = Date()
        guard let url = feedURL else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let remote = obj["version"] as? String
            else { return }
            let newer = Self.isNewer(remote, than: self.current)
            // `url` peut être relatif ("Cockpit.dmg") : on le résout contre le feed.
            let raw = (obj["url"] as? String) ?? "Cockpit.dmg"
            let link = URL(string: raw, relativeTo: url)?.absoluteURL
                ?? URL(string: self.fallbackBase)!
            let notes = obj["notes"] as? String ?? ""
            DispatchQueue.main.async {
                self.available = newer ? Available(version: remote, url: link, notes: notes) : nil
            }
        }.resume()
    }

    /// Comparaison numérique champ par champ ("0.2" > "0.1.9" faux : 0.2 > 0.1.9 vrai).
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

    func openDownload() {
        if let u = available?.url { NSWorkspace.shared.open(u) }
    }
}
