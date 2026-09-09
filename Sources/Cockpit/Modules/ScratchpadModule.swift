import SwiftUI

extension Notification.Name {
    static let cockpitScratchpadChanged = Notification.Name("cockpit.scratchpad.changed")
}

/// Bloc-notes libre, enregistré en continu dans Application Support.
struct ScratchpadModule: View {
    @State private var text = ScratchStore.load()
    @State private var saved = true

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.ui(12.5))
                .scrollContentBackground(.hidden)
                .padding(8)
                .onChange(of: text) { _, new in
                    saved = false
                    ScratchStore.scheduleSave(new) { saved = true }
                }
            HStack {
                Text(saved ? "Enregistré" : "…")
                    .font(.ui(9)).foregroundStyle(Theme.textFaint)
                Spacer()
                Text("\(text.count) caractères")
                    .font(.ui(9)).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cockpitSettingsImported)) { _ in
            let fresh = ScratchStore.load()
            if fresh != text { text = fresh }
        }
    }
}

enum ScratchStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cockpit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scratchpad.txt")
    }

    static func load() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Écrit sans passer par le débounce (import depuis la synchro).
    static func overwrite(_ text: String) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static var work: DispatchWorkItem?

    static func scheduleSave(_ text: String, done: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                done()
                NotificationCenter.default.post(name: .cockpitScratchpadChanged, object: nil)
            }
        }
        work = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: w)
    }
}
