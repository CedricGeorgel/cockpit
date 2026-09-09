import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        configureWindow()
        // La fenêtre SwiftUI n'existe pas toujours au tout premier instant.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.configureWindow() }

        if UserDefaults.standard.object(forKey: "cockpit.menubar") as? Bool ?? true {
            MenuBarController.shared.setVisible(true)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.ensureAllWindowsOnScreen() }
    }

    private var menuBarOn: Bool { UserDefaults.standard.object(forKey: "cockpit.menubar") as? Bool ?? true }

    private func configureWindow() {
        guard let w = NSApp.windows.first(where: { $0.contentView != nil && $0.canBecomeMain }) else { return }
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = false
        w.delegate = self
        w.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.086, green: 0.096, blue: 0.114, alpha: 1)
                : NSColor(srgbRed: 0.945, green: 0.953, blue: 0.969, alpha: 1)
        }
        w.setFrameAutosaveName("CockpitMainWindow")
        ensureOnScreen(w)
        w.makeKeyAndOrderFront(nil)
    }

    /// Fenêtre fermée alors que la barre de menus est active : on masque au lieu
    /// de fermer, l'app continue de tourner.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard menuBarOn else { return true }
        sender.orderOut(nil)
        return false
    }

    private func ensureAllWindowsOnScreen() {
        NSApp.windows.forEach(ensureOnScreen)
    }

    /// Recadre la fenêtre si elle est hors de tout écran visible (moniteur
    /// débranché, disposition changée…) ou d'une forme inutilisable.
    private func ensureOnScreen(_ w: NSWindow) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let f = w.frame

        let visibleOverlap = screens.map { $0.visibleFrame.intersection(f) }
            .map { $0.width * $0.height }.max() ?? 0
        let mostlyVisible = visibleOverlap > f.width * f.height * 0.5
        let usableShape = f.width >= 900 && f.height >= 600

        guard !mostlyVisible || !usableShape else { return }

        let vis = (w.screen ?? NSScreen.main ?? screens[0]).visibleFrame
        let size = NSSize(width: min(1440, vis.width - 60), height: min(900, vis.height - 60))
        let origin = NSPoint(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2)
        w.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !menuBarOn }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let w = sender.windows.first {
            ensureOnScreen(w)
            w.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// Barrière de connexion : pas de compte relié → écran de connexion, rien ne
/// tourne. Le jeton de session (`cockpit.remote.token`) fait la bascule.
struct RootView: View {
    @AppStorage("cockpit.remote.token") private var token = ""

    var body: some View {
        if token.isEmpty {
            SignInView()
        } else {
            DashboardView()
        }
    }
}

@main
struct CockpitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Cockpit") {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings { SettingsView() }
    }
}
