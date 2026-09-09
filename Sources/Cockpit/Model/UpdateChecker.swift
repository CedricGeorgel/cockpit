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

    private init() {}

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.check()
        }
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

    func check() {
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
            let link = (obj["url"] as? String).flatMap(URL.init(string:))
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
