import Foundation
import AppKit
import SwiftUI

/// Pont vers Prisme : plutôt que de refaire l'analyse d'espace disque, on
/// lance Prisme en mode `--export` (aucune fenêtre) et on lit son JSON.
///
///     Prisme.app/Contents/MacOS/Prisme --export <dossier> --format json --depth 2
enum PrismeAPI {

    // MARK: Schéma (contrat de données de Prisme, schemaVersion 1)

    struct Report: Codable {
        var schemaVersion: Int
        var generatedAt: String
        var scan: Scan
        var volume: Volume?
        var categories: [Category]
        var segments: [Segment]

        struct Scan: Codable {
            var rootPath: String
            var rootName: String
            var isVolumeRoot: Bool
            var fileCount: Int
            var measuredBytes: Int64
            var unmeasuredBytes: Int64
            var freeBytes: Int64
            var circleTotalBytes: Int64
        }
        struct Volume: Codable {
            var name: String
            var capacityBytes: Int64
            var usedBytes: Int64
            var freeBytes: Int64
        }
        struct Category: Codable {
            var id: String
            var labelFr: String
            var bytes: Int64
            var colorHexLight: String
            var colorHexDark: String
        }
        struct Segment: Codable {
            var name: String
            var path: String
            var isDir: Bool
            var bytes: Int64
            var category: String
            var fileCount: Int?
            var children: [Segment]?
        }

        func color(_ categoryID: String, dark: Bool) -> String {
            let c = categories.first { $0.id == categoryID }
            return (dark ? c?.colorHexDark : c?.colorHexLight) ?? (dark ? "#7b8492" : "#8892a3")
        }
    }

    enum PrismeError: LocalizedError {
        case notFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notFound:      return "Prisme est introuvable"
            case .failed(let m): return "Prisme : \(m)"
            }
        }
    }

    // MARK: Localisation de l'app

    private static let customPathKey = "cockpit.prisme.path"

    static var executableURL: URL? {
        if let custom = UserDefaults.standard.string(forKey: customPathKey) {
            let exe = bundleExecutable(URL(fileURLWithPath: custom))
            if FileManager.default.isExecutableFile(atPath: exe.path) { return exe }
        }
        let candidates = [
            "/Applications/Prisme.app",
            "/Users/\(NSUserName())/Applications/Prisme.app",
            "/Users/\(NSUserName())/Documents/Prisme/Prisme.app",
        ].map(URL.init(fileURLWithPath:))
        for app in candidates {
            let exe = bundleExecutable(app)
            if FileManager.default.isExecutableFile(atPath: exe.path) { return exe }
        }
        // Recherche par identifiant (si l'app est enregistrée par Launch Services).
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.prisme.diskviz") {
            return bundleExecutable(app)
        }
        return nil
    }

    static var isAvailable: Bool { executableURL != nil }

    static func setCustomPath(_ appURL: URL) {
        UserDefaults.standard.set(appURL.path, forKey: customPathKey)
    }

    private static func bundleExecutable(_ app: URL) -> URL {
        let name = app.deletingPathExtension().lastPathComponent
        return app.appendingPathComponent("Contents/MacOS/\(name)")
    }

    // MARK: Analyse

    static func analyze(path: String, depth: Int = 2, maxChildren: Int = 24) async throws -> Report {
        guard let exe = executableURL else { throw PrismeError.notFound }
        // Le bundle .app (…/Contents/MacOS/Prisme → …/Prisme.app).
        let appURL = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        // Lancé comme processus indépendant (pas un enfant de Cockpit) : les
        // autorisations disque appliquées sont celles de Prisme, pas les nôtres.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cockpit-prisme-\(UUID().uuidString).json")
        try? FileManager.default.removeItem(at: outURL)

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--export", path, "--format", "json", "--out", outURL.path,
                            "--depth", String(depth), "--max-children", String(maxChildren),
                            "--color", "type"]
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = true

        let running = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)

        // Prisme quitte dès qu'il a écrit le fichier.
        let deadline = Date().addingTimeInterval(240)
        while !running.isTerminated, Date() < deadline {
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        if !running.isTerminated { running.forceTerminate() }

        guard let data = try? Data(contentsOf: outURL) else {
            throw PrismeError.failed("aucune sortie (autorise l'accès au disque à Prisme)")
        }
        try? FileManager.default.removeItem(at: outURL)
        do {
            return try JSONDecoder().decode(Report.self, from: data)
        } catch {
            throw PrismeError.failed("JSON illisible")
        }
    }

    // MARK: Cache

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cockpit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prisme-report.json")
    }

    static func loadCached() -> Report? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Report.self, from: data)
    }

    static func cache(_ report: Report) {
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}

extension Color {
    /// « #rrggbb » → Color.
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }
}
