import Foundation
import AppKit
import AuthenticationServices
import IOKit
import CryptoKit

/// Fournit la fenêtre d'ancrage pour `ASWebAuthenticationSession` (macOS).
final class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

private func SHA256hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Pont vers le relais PHP qui alimente la PWA mobile.
///
/// L'URL configurée pointe vers `relay.php`. Deux « fichiers » logiques,
/// jeton Bearer obligatoire :
///  - `?f=snapshot` : écrit (POST) par le Mac toutes les ~60 s, lu par le téléphone.
///  - `?f=commands` : actions déposées par le téléphone (cocher une tâche,
///                    éditer le bloc-notes…), relevées et appliquées ici puis
///                    marquées « faites » via `appliedCommandIds` dans
///                    l'instantané suivant.
///
/// Contrat complet : `docs/mobile-sync.md`.
final class RemoteBridge {
    static let shared = RemoteBridge()

    private let urlKey = "cockpit.remote.url"
    private let tokenKey = "cockpit.remote.token"
    private let instanceKey = "cockpit.remote.instance"
    private let emailKey = "cockpit.remote.email"
    private let appliedKey = "cockpit.remote.appliedCmds"
    private let executesKey = "cockpit.remote.executesCommands"

    /// Identifiant stable de cette machine (dérivé de l'UUID matériel).
    let deviceID: String = {
        let port: mach_port_t
        if #available(macOS 12.0, *) { port = kIOMainPortDefault } else { port = kIOMasterPortDefault }
        let svc = IOServiceGetMatchingService(port, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if svc != 0 { IOObjectRelease(svc) } }
        let uuid = (IORegistryEntryCreateCFProperty(svc, "IOPlatformUUID" as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? NSUserName()
        return String(SHA256hex(uuid).prefix(16))
    }()

    /// Ce Mac applique les actions déposées depuis le mobile (défaut : oui).
    /// À décocher sur les Macs secondaires pour éviter les doublons.
    var executesCommands: Bool {
        get { UserDefaults.standard.object(forKey: executesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: executesKey); restart() }
    }

    private var snapshotTimer: Timer?
    private var commandTimer: Timer?
    private var settingsTimer: Timer?
    private var pushWork: DispatchWorkItem?
    private var settingsPushWork: DispatchWorkItem?
    private var applyingSettings = false
    private var started = false

    /// États des autres appareils de la flotte. Mis à jour par `pullFleet`,
    /// signalé par `.cockpitFleetUpdated`.
    private(set) var fleet: [FleetDevice] = []
    struct FleetDevice: Identifiable {
        var id: String { deviceId }
        var deviceId: String
        var name: String
        var pushedAt: Date
        var macPercent: Int?
        var macCharging: Bool
        var macMinutesRemaining: Int?
        var diskName: String?
        var diskUsed: Int64 = 0
        var diskTotal: Int64 = 0
        var diskFree: Int64 = 0
        var btDevices: [DeviceBattery] = []
        var isSelf: Bool
    }

    // MARK: Config

    private var baseURLString: String { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    var token: String { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
    var instance: String { UserDefaults.standard.string(forKey: instanceKey) ?? "" }
    /// Adresse Google du compte connecté (affichage seulement).
    var accountEmail: String { UserDefaults.standard.string(forKey: emailKey) ?? "" }

    /// Adresse du relais telle que saisie par l'utilisateur, normalisée en
    /// `https://…/relay.php`. Vide si rien n'est encore configuré.
    var relayURLString: String {
        get { normalizedRelay(baseURLString) }
        set { UserDefaults.standard.set(normalizedRelay(newValue), forKey: urlKey) }
    }
    private func normalizedRelay(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "" }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
        if let host = URL(string: s)?.host {
            let isLocal = host == "localhost" || host.hasSuffix(".local")
                || host.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
            if s.hasPrefix("http://") && !isLocal { s = "https://" + s.dropFirst("http://".count) }
        }
        if !s.hasSuffix("relay.php") {
            if !s.hasSuffix("/") { s += "/" }
            s += "relay.php"
        }
        return s
    }

    /// Configure le pont à partir d'une « clé de connexion » (base64url d'un
    /// JSON `{u, i, t}`), ancienne méthode. Renvoie `false` si la clé est illisible.
    @discardableResult
    func applyKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var b64 = trimmed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              var u = obj["u"], let i = obj["i"], let t = obj["t"],
              u.hasPrefix("http"), !i.isEmpty, !t.isEmpty else { return false }
        // ATS bloque le HTTP en clair vers un vrai domaine : on passe en HTTPS
        // (sauf localhost / IP / .local pour les tests).
        if u.hasPrefix("http://"),
           let host = URL(string: u)?.host,
           host.contains("."), !host.hasSuffix(".local"),
           URL(string: u)?.host.flatMap({ $0.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) }) == nil {
            u = "https://" + u.dropFirst("http://".count)
        }
        let d = UserDefaults.standard
        d.set(u, forKey: urlKey); d.set(i, forKey: instanceKey); d.set(t, forKey: tokenKey)
        d.removeObject(forKey: appliedKey)
        d.set(false, forKey: "cockpit.localMode")
        restart()
        return true
    }

    // MARK: Connexion Google

    private var authSession: ASWebAuthenticationSession?
    private var authAnchor: AuthAnchor?

    static func err(_ m: String) -> NSError {
        NSError(domain: "Cockpit.RemoteBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }

    /// Ouvre « Se connecter avec Google » dans la fenêtre d'authentification système.
    /// `relay` : adresse du relais saisie par l'utilisateur (normalisée ici).
    func signInWithGoogle(relay: String, completion: @escaping (Result<String, Error>) -> Void) {
        relayURLString = relay
        guard var c = URLComponents(string: relayURLString), c.host != nil else {
            completion(.failure(Self.err("Adresse du relais invalide."))); return
        }
        c.queryItems = [URLQueryItem(name: "auth", value: "start"),
                        URLQueryItem(name: "app", value: "1")]
        guard let url = c.url else { completion(.failure(Self.err("URL invalide."))); return }

        let anchor = AuthAnchor()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "cockpit") { [weak self] cb, error in
            guard let self else { return }
            self.authSession = nil; self.authAnchor = nil
            if let error {
                let e = error as? ASWebAuthenticationSessionError
                if e?.code == .canceledLogin { completion(.failure(Self.err("Connexion annulée."))) }
                else { completion(.failure(error)) }
                return
            }
            guard let cb,
                  let frag = URLComponents(url: cb, resolvingAgainstBaseURL: false)?.fragment else {
                completion(.failure(Self.err("Réponse de connexion vide."))); return
            }
            var pairs: [String: String] = [:]
            for kv in frag.split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1)
                if p.count == 2 { pairs[String(p[0])] = String(p[1]).removingPercentEncoding ?? String(p[1]) }
            }
            guard let t = pairs["t"], !t.isEmpty else {
                completion(.failure(Self.err("Jeton absent de la réponse."))); return
            }
            let d = UserDefaults.standard
            d.set(t, forKey: self.tokenKey)
            d.removeObject(forKey: self.instanceKey)
            d.set(pairs["e"] ?? "", forKey: self.emailKey)
            d.removeObject(forKey: self.appliedKey)
            d.set(false, forKey: "cockpit.localMode")
            self.restart()
            completion(.success(pairs["e"] ?? ""))
        }
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        authAnchor = anchor
        authSession = session
        if !session.start() {
            authSession = nil; authAnchor = nil
            completion(.failure(Self.err("Impossible d'ouvrir la fenêtre de connexion.")))
        }
    }

    func disconnect() {
        let tok = token, relay = relayURLString
        let d = UserDefaults.standard
        [tokenKey, instanceKey, emailKey, appliedKey].forEach(d.removeObject(forKey:))
        d.set(true, forKey: "cockpit.localMode")   // on reste utilisable en local, pas d'écran de connexion
        [snapshotTimer, commandTimer, settingsTimer].forEach { $0?.invalidate() }
        started = false
        NotificationCenter.default.post(name: .cockpitFleetUpdated, object: nil)
        // Révoque la session côté serveur (au mieux).
        guard !tok.isEmpty, var c = URLComponents(string: relay) else { return }
        c.queryItems = [URLQueryItem(name: "auth", value: "logout")]
        guard let url = c.url else { return }
        var r = URLRequest(url: url); r.httpMethod = "POST"
        r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: r).resume()
    }

    private var base: URLComponents? {
        let s = baseURLString
        guard s.hasPrefix("http"), let c = URLComponents(string: s), c.host != nil,
              !token.isEmpty else { return nil }
        return c
    }
    var isConfigured: Bool { base != nil }

    // MARK: Cycle de vie

    private init() {}

    func start() {
        guard !started, isConfigured else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.applyingSettings else { return }
            self.schedulePush()
        }
        for name in [Notification.Name.cockpitScratchpadChanged, .cockpitLocalSettingChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.scheduleSettingsPush()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.pullSettings(); self?.pullFleet() }

        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.schedulePush(delay: 0)
        }
        commandTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.pollCommands()
        }
        settingsTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.pullFleet(); self?.pullSettings(); self?.scheduleSettingsPush(delay: 0)
        }
        schedulePush(delay: 2)
        pollCommands()
        pullSettings()
        pullFleet()
    }

    private func restart() {
        [snapshotTimer, commandTimer, settingsTimer].forEach { $0?.invalidate() }
        started = false
        if isConfigured { start() }
    }

    func syncNow() { schedulePush(delay: 0); pollCommands(); pullSettings(); pullFleet() }

    /// Retire l'instantané d'un autre appareil du serveur. S'il tourne encore,
    /// il se re-signalera au prochain push : c'est surtout utile pour un Mac
    /// éteint / mis de côté dont on ne veut plus voir les données.
    func forgetDevice(_ id: String, completion: ((Bool) -> Void)? = nil) {
        guard id != deviceID, !id.isEmpty, var c = base else { completion?(false); return }
        var items = c.queryItems ?? []
        items.removeAll { ["f", "i", "d", "auth"].contains($0.name) }
        items.append(URLQueryItem(name: "f", value: "device"))
        items.append(URLQueryItem(name: "d", value: id))
        items.append(URLQueryItem(name: "forget", value: "1"))
        if !instance.isEmpty { items.append(URLQueryItem(name: "i", value: instance)) }
        c.queryItems = items
        guard let url = c.url else { completion?(false); return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        if !token.isEmpty {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        }
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
            DispatchQueue.main.async {
                if ok {
                    self.fleet.removeAll { $0.deviceId == id }
                    NotificationCenter.default.post(name: .cockpitFleetUpdated, object: nil)
                }
                completion?(ok)
            }
        }.resume()
    }

    // MARK: HTTP

    private func request(_ f: String, method: String, body: Data? = nil) -> URLRequest? {
        guard var c = base else { return nil }
        var items = c.queryItems ?? []
        items.removeAll { ["f", "i", "d", "auth"].contains($0.name) }
        items.append(URLQueryItem(name: "f", value: f))
        if !instance.isEmpty { items.append(URLQueryItem(name: "i", value: instance)) }
        if f == "device" { items.append(URLQueryItem(name: "d", value: deviceID)) }
        c.queryItems = items
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 20
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if !token.isEmpty {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue(token, forHTTPHeaderField: "X-Auth-Token")   // secours si Authorization filtrée
        }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func get(_ f: String, _ done: @escaping (Data?) -> Void) {
        guard let r = request(f, method: "GET") else { return done(nil) }
        URLSession.shared.dataTask(with: r) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
            DispatchQueue.main.async { done(ok ? data : nil) }
        }.resume()
    }

    private func post(_ f: String, _ data: Data) {
        guard let r = request(f, method: "POST", body: data) else { return }
        URLSession.shared.dataTask(with: r).resume()
    }

    // MARK: Instantané (Mac → serveur)

    private func schedulePush(delay: TimeInterval = 3) {
        guard isConfigured else { return }
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pushSnapshot() }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func pushSnapshot() {
        let applied = Array(appliedIDs.suffix(120))
        let id = deviceID
        Task { @MainActor in
            var snap = SnapshotBuilder.build(appliedCommandIds: applied)
            snap.deviceId = id
            snap.platform = "mac"
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.withoutEscapingSlashes]
            guard let data = try? enc.encode(snap) else { return }
            self.post("device", data)
        }
    }

    // MARK: Commandes (téléphone → Mac)

    private struct CommandFile: Codable { var commands: [RemoteCommand] }
    private struct RemoteCommand: Codable {
        var id: String
        var kind: String
        var args: [String: String]?
    }

    private var appliedIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: appliedKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: appliedKey) }
    }

    private func pollCommands() {
        guard isConfigured, executesCommands else { return }
        get("commands") { [weak self] data in
            guard let self, let data else { return }
            let dec = JSONDecoder()
            guard let file = try? dec.decode(CommandFile.self, from: data) else { return }
            let known = Set(self.appliedIDs)
            var newlyApplied: [String] = []
            for cmd in file.commands where !known.contains(cmd.id) {
                self.apply(cmd)
                newlyApplied.append(cmd.id)
            }
            if !newlyApplied.isEmpty {
                self.appliedIDs = self.appliedIDs + newlyApplied
                self.schedulePush(delay: 1)
            }
        }
    }

    private func apply(_ cmd: RemoteCommand) {
        let a = cmd.args ?? [:]
        let s = Services.shared
        switch cmd.kind {
        case "completeTodo":
            if let id = a["id"] { s.todos.complete(id) }
        case "addReminder":
            if let t = a["title"], !t.isEmpty { s.todos.addReminder(t) }
        case "refreshMail":    s.mail.refreshAll()
        case "refreshParcels": s.parcels.refresh()
        default: break
        }
    }

    // MARK: Réglages partagés (remplace la synchro iCloud)

    private let stampsKey = "cockpit.remote.settingsStamps"
    private struct Field: Codable { var v: JSONValue; var at: Double }
    private struct SettingsFile: Codable {
        var scratchpad: Field?
        var weatherPlace: Field?
        var newsFeeds: Field?
        var callContacts: Field?
        var columns: Field?
        var mailKeywords: Field?
        var newsRead: Field?     // fusion (union), pas dernier-qui-écrit
    }
    private var stamps: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: stampsKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: stampsKey) }
    }

    private func scheduleSettingsPush(delay: TimeInterval = 2) {
        guard isConfigured, !applyingSettings else { return }
        settingsPushWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.pushSettings() }
        settingsPushWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func pullSettings() {
        guard isConfigured else { return }
        get("settings") { [weak self] data in
            guard let self, let data,
                  let file = try? JSONDecoder().decode(SettingsFile.self, from: data) else { return }
            var st = self.stamps
            var changed = false
            self.applyingSettings = true
            let d = UserDefaults.standard
            func take(_ key: String, _ f: Field?, _ apply: (JSONValue) -> Bool) {
                guard let f, f.at > (st[key] ?? 0) else { return }
                if apply(f.v) { st[key] = f.at; changed = true }
            }
            take("scratchpad", file.scratchpad) { if case .string(let s) = $0 { ScratchStore.overwrite(s); return true }; return false }
            take("weatherPlace", file.weatherPlace) { if case .string(let s) = $0, !s.isEmpty { d.set(s, forKey: "cockpit.weather.place"); return true }; return false }
            take("newsFeeds", file.newsFeeds) {
                guard case .array(let a) = $0 else { return false }
                let feeds = a.compactMap(\.stringValue)
                // ne jamais écraser des flux locaux par une liste vide venue d'un autre appareil
                if feeds.isEmpty && !(d.array(forKey: "cockpit.news.feeds") as? [String] ?? []).isEmpty { return false }
                d.set(feeds, forKey: "cockpit.news.feeds"); return true
            }
            take("callContacts", file.callContacts) { if case .string(let b) = $0, !b.isEmpty, let raw = Data(base64Encoded: b) { d.set(raw, forKey: "cockpit.calltime.contacts.v1"); return true }; return false }
            take("columns", file.columns) { if case .string(let b) = $0, !b.isEmpty, let raw = Data(base64Encoded: b) { d.set(raw, forKey: "cockpit.columns.v1"); return true }; return false }
            take("mailKeywords", file.mailKeywords) { if case .array(let a) = $0 { d.set(a.compactMap(\.stringValue), forKey: "cockpit.mail.keywords"); return true }; return false }
            // newsRead : union avec l'existant (pas de LWW), pour ne perdre aucun « lu »
            if case .array(let a)? = file.newsRead?.v {
                let incoming = Set(a.compactMap(\.stringValue))
                let current = Set(d.stringArray(forKey: "cockpit.news.read") ?? [])
                let merged = current.union(incoming)
                if merged != current {
                    d.set(Array(merged.suffix(300)), forKey: "cockpit.news.read")
                    changed = true
                }
            }
            if changed { self.stamps = st }
            self.applyingSettings = false
            if changed {
                NotificationCenter.default.post(name: .cockpitScratchpadChanged, object: nil)
                NotificationCenter.default.post(name: .cockpitSettingsImported, object: nil)
            }
        }
    }

    private var lastSettingsHash = 0

    /// Empreinte des réglages locaux, pour éviter un aller-retour serveur inutile.
    private func localSettingsHash() -> Int {
        let d = UserDefaults.standard
        var h = Hasher()
        h.combine(ScratchStore.load())
        h.combine(d.string(forKey: "cockpit.weather.place") ?? "")
        h.combine(d.array(forKey: "cockpit.news.feeds") as? [String] ?? [])
        h.combine(d.data(forKey: "cockpit.calltime.contacts.v1"))
        h.combine(d.data(forKey: "cockpit.columns.v1"))
        h.combine(d.array(forKey: "cockpit.mail.keywords") as? [String] ?? [])
        h.combine((d.stringArray(forKey: "cockpit.news.read") ?? []).sorted())
        return h.finalize()
    }

    private func pushSettings() {
        guard isConfigured, !applyingSettings else { return }
        let hash = localSettingsHash()
        guard hash != lastSettingsHash else { return }   // rien de neuf localement
        get("settings") { [weak self] data in
            guard let self else { return }
            self.lastSettingsHash = hash
            var file = data.flatMap { try? JSONDecoder().decode(SettingsFile.self, from: $0) } ?? SettingsFile()
            var st = self.stamps
            let now = Date().timeIntervalSince1970
            let d = UserDefaults.standard
            var changed = false
            func upd(_ key: String, _ current: JSONValue, _ existing: Field?, _ set: (Field) -> Void) {
                if let existing, existing.v == current { return }   // inchangé
                set(Field(v: current, at: now)); st[key] = now; changed = true
            }
            upd("scratchpad", .string(ScratchStore.load()), file.scratchpad) { file.scratchpad = $0 }
            let place = d.string(forKey: "cockpit.weather.place") ?? ""
            if !place.isEmpty { upd("weatherPlace", .string(place), file.weatherPlace) { file.weatherPlace = $0 } }
            let feeds = d.array(forKey: "cockpit.news.feeds") as? [String] ?? []
            if !feeds.isEmpty { upd("newsFeeds", .array(feeds.map(JSONValue.string)), file.newsFeeds) { file.newsFeeds = $0 } }
            if let raw = d.data(forKey: "cockpit.calltime.contacts.v1"), raw.count > 2 {
                upd("callContacts", .string(raw.base64EncodedString()), file.callContacts) { file.callContacts = $0 }
            }
            if let raw = d.data(forKey: "cockpit.columns.v1") {
                upd("columns", .string(raw.base64EncodedString()), file.columns) { file.columns = $0 }
            }
            let kw = d.array(forKey: "cockpit.mail.keywords") as? [String] ?? []
            upd("mailKeywords", .array(kw.map(JSONValue.string)), file.mailKeywords) { file.mailKeywords = $0 }
            let localNr = Set(d.stringArray(forKey: "cockpit.news.read") ?? [])
            var serverNr = Set<String>()
            if case .array(let a)? = file.newsRead?.v { serverNr = Set(a.compactMap(\.stringValue)) }
            if !localNr.isSubset(of: serverNr) {
                let union: [String] = Array(Array(serverNr.union(localNr)).suffix(300))
                file.newsRead = Field(v: .array(union.map(JSONValue.string)), at: now); changed = true
            }
            guard changed else { return }
            self.applyingSettings = true
            self.stamps = st
            self.applyingSettings = false
            if let out = try? JSONEncoder().encode(file) { self.post("settings", out) }
        }
    }

    // MARK: Flotte (lecture des autres Macs)

    private func pullFleet() {
        guard isConfigured else { return }
        get("fleet") { [weak self] data in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["devices"] as? [[String: Any]] else { return }
            let mine = self.deviceID
            let iso = ISO8601DateFormatter()
            self.fleet = arr.map { dev in
                let bat = dev["battery"] as? [String: Any]
                let mac = bat?["mac"] as? [String: Any]
                let disk = dev["disk"] as? [String: Any]
                let bts = (bat?["devices"] as? [[String: Any]] ?? []).compactMap { b -> DeviceBattery? in
                    guard let n = b["name"] as? String, let p = b["percent"] as? Int else { return nil }
                    let seen = (b["seenAt"] as? String).flatMap { iso.date(from: $0) }
                    return DeviceBattery(name: n, icon: b["icon"] as? String ?? "dot.radiowaves.right",
                                         percent: p, extra: b["extra"] as? String, lastSeen: seen)
                }
                return FleetDevice(
                    deviceId: dev["deviceId"] as? String ?? UUID().uuidString,
                    name: dev["device"] as? String ?? "Mac",
                    pushedAt: (dev["generatedAt"] as? String).flatMap { iso.date(from: $0) } ?? Date(),
                    macPercent: mac?["percent"] as? Int,
                    macCharging: mac?["charging"] as? Bool ?? false,
                    macMinutesRemaining: mac?["minutesRemaining"] as? Int,
                    diskName: disk?["volumeName"] as? String,
                    diskUsed: (disk?["usedBytes"] as? NSNumber)?.int64Value ?? 0,
                    diskTotal: (disk?["totalBytes"] as? NSNumber)?.int64Value ?? 0,
                    diskFree: (disk?["freeBytes"] as? NSNumber)?.int64Value ?? 0,
                    btDevices: bts,
                    isSelf: (dev["deviceId"] as? String) == mine)
            }
            NotificationCenter.default.post(name: .cockpitFleetUpdated, object: nil)
        }
    }
}

/// Valeur JSON minimale pour les champs de réglages hétérogènes.
enum JSONValue: Codable, Equatable {
    case string(String), array([JSONValue])

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .array((try? c.decode([JSONValue].self)) ?? []) }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        }
    }
}
