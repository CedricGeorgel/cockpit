import AppKit
import SwiftUI
import Combine

/// Icône + statut dans la barre de menus. Clic gauche : ouvre / cache la
/// fenêtre. Clic droit : petit menu.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var item: NSStatusItem?
    private var bag = Set<AnyCancellable>()

    private override init() { super.init() }

    var isVisible: Bool { item != nil }

    func setVisible(_ on: Bool) {
        if on { install() } else { remove() }
    }

    private func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.imagePosition = .imageLeading
        it.button?.font = .menuBarFont(ofSize: 0)
        it.button?.target = self
        it.button?.action = #selector(handleClick)
        it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item = it
        render()

        CockpitStatus.shared.$menuLine
            .combineLatest(CockpitStatus.shared.$symbol)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &bag)
    }

    private func remove() {
        bag.removeAll()
        if let it = item { NSStatusBar.system.removeStatusItem(it) }
        item = nil
    }

    private func render() {
        guard let button = item?.button else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let img = NSImage(systemSymbolName: CockpitStatus.shared.symbol,
                          accessibilityDescription: "Cockpit")?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        button.image = img
        let line = CockpitStatus.shared.menuLine
        button.title = line.isEmpty ? "" : " \(line)"
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            AppWindow.toggle()
        }
    }

    private func showMenu() {
        let m = NSMenu()
        for (title, sel, key) in [
            ("Ouvrir Cockpit", #selector(openApp), ""),
            ("Rafraîchir tout", #selector(refreshAll), ""),
        ] { m.addItem(withTitle: title, action: sel, keyEquivalent: key).target = self }
        m.addItem(.separator())
        m.addItem(withTitle: "Réglages…", action: #selector(openSettings), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quitter Cockpit", action: #selector(quit), keyEquivalent: "").target = self

        if let button = item?.button {
            m.popUp(positioning: nil,
                    at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        }
    }

    @objc private func openApp() { AppWindow.show() }
    @objc private func refreshAll() { Services.shared.refreshEverything() }
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Accès à la fenêtre principale du tableau de bord (unique, jamais réellement
/// fermée quand la barre de menus est active : masquée).
enum AppWindow {
    static var main: NSWindow? {
        NSApp.windows.first { $0.frameAutosaveName == "CockpitMainWindow" }
            ?? NSApp.windows.first { $0.canBecomeMain && $0.contentView != nil && !($0 is NSPanel) }
    }
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        main?.makeKeyAndOrderFront(nil)
    }
    static func toggle() {
        guard let w = main else { show(); return }
        if w.isVisible && NSApp.isActive { w.orderOut(nil) }
        else { show() }
    }
}
