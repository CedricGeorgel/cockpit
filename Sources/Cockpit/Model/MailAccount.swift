import Foundation
import CryptoKit
import IOKit

/// Une boîte mail IMAP. L'authentification se fait par mot de passe (FAI,
/// mot de passe d'application) ou par OAuth (Gmail / Outlook modernes).
/// Les secrets sont gardés à part, dans un fichier chiffré local.
struct MailAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 993
    var username: String
    var auth: AuthKind = .password

    enum AuthKind: Codable, Equatable {
        case password
        case oauth(provider: OAuthProvider, clientID: String)

        var isOAuth: Bool { if case .oauth = self { return true } else { return false } }
    }

    // Décodage tolérant : un compte enregistré avant l'ajout d'un champ ne
    // doit pas disparaître.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        host = (try? c.decode(String.self, forKey: .host)) ?? ""
        port = (try? c.decode(Int.self, forKey: .port)) ?? 993
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        auth = (try? c.decode(AuthKind.self, forKey: .auth)) ?? .password
    }

    init(id: UUID = UUID(), name: String, host: String, port: Int = 993,
         username: String, auth: AuthKind = .password) {
        self.id = id; self.name = name; self.host = host
        self.port = port; self.username = username; self.auth = auth
    }

    static let presets: [(name: String, host: String, port: Int)] = [
        ("Gmail",   "imap.gmail.com",       993),
        ("Outlook perso", "imap-mail.outlook.com", 993),
        ("iCloud",  "imap.mail.me.com",     993),
        ("Orange",  "imap.orange.fr",       993),
        ("Free",    "imap.free.fr",         993),
        ("SFR",     "imap.sfr.fr",          993),
        ("Bouygues", "imap.bbox.fr",        993),
        ("OVH",     "ssl0.ovh.net",         993),
        ("Yahoo",   "imap.mail.yahoo.com",  993),
        ("Autre",   "",                     993),
    ]
}

/// Métadonnées des comptes (préférences) + coffre chiffré pour les secrets
/// (mot de passe, client secret OAuth, refresh token, jeton d'accès en cache).
enum MailAccountStore {
    private static let key = "cockpit.mail.accounts"

    static func load() -> [MailAccount] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([MailAccount].self, from: data) else { return [] }
        return list
    }

    static func save(_ accounts: [MailAccount]) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: Secrets

    struct Secrets: Codable {
        var password: String?
        var clientSecret: String?
        var tokens: OAuthTokens?
    }

    static func secrets(for id: UUID) -> Secrets {
        readVault()[id.uuidString] ?? Secrets()
    }

    static func update(_ id: UUID, _ change: (inout Secrets) -> Void) {
        var v = readVault()
        var s = v[id.uuidString] ?? Secrets()
        change(&s)
        v[id.uuidString] = s
        writeVault(v)
    }

    static func delete(_ id: UUID) {
        var v = readVault(); v[id.uuidString] = nil; writeVault(v)
    }

    // Coffre chiffré local plutôt que le Trousseau : une app signée « ad hoc »
    // se fait redemander le mot de passe du Trousseau à chaque recompilation.
    // AES-GCM, clé dérivée de l'UUID matériel du Mac + l'identifiant utilisateur.

    private static var vaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cockpit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mail.vault")
    }

    private static let vaultKey: SymmetricKey = {
        var seed = "cockpit.mail." + NSUserName()
        let matching = IOServiceMatching("IOPlatformExpertDevice")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        if service != 0 {
            if let cf = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0) {
                seed += (cf.takeRetainedValue() as? String) ?? ""
            }
            IOObjectRelease(service)
        }
        return SymmetricKey(data: SHA256.hash(data: Data(seed.utf8)))
    }()

    private static func readVault() -> [String: Secrets] {
        guard let blob = try? Data(contentsOf: vaultURL),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let clear = try? AES.GCM.open(box, using: vaultKey),
              let dict = try? JSONDecoder().decode([String: Secrets].self, from: clear) else { return [:] }
        return dict
    }

    private static func writeVault(_ dict: [String: Secrets]) {
        guard let clear = try? JSONEncoder().encode(dict),
              let box = try? AES.GCM.seal(clear, using: vaultKey),
              let blob = box.combined else { return }
        try? blob.write(to: vaultURL, options: [.atomic, .completeFileProtection])
    }
}
