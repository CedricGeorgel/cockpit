import SwiftUI
import AppKit

struct NowPlaying {
    var app: String          // "Musique" ou "Spotify"
    var bundleID: String
    var title: String
    var artist: String
    var album: String
    var playing: Bool
}

final class NowPlayingModel: ObservableObject {
    @Published var current: NowPlaying?
    @Published var blocked = false

    private var timer: Timer?

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
    }

    private let targets = [
        ("Spotify", "com.spotify.client"),
        ("Musique", "com.apple.Music"),
    ]

    func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
            let anyRunning = self.targets.contains { running.contains($0.1) }
            var found: NowPlaying?
            var denied = false
            for (name, bundle) in self.targets where running.contains(bundle) {
                switch self.query(app: name == "Musique" ? "Music" : name, display: name, bundle: bundle) {
                case .success(let np): if np.playing || found == nil { found = np }
                case .denied: denied = true
                case .none: break
                }
                if found?.playing == true { break }
            }
            DispatchQueue.main.async {
                if !anyRunning {
                    self.current = nil
                    self.blocked = false
                } else if let found {
                    self.current = found
                    self.blocked = false
                } else if denied {
                    self.blocked = true
                }
                // Sinon (erreur transitoire, AppleEvent timeout) : on garde l'état affiché.
            }
        }
    }

    private enum QueryResult { case success(NowPlaying), denied, none }

    private func query(app: String, display: String, bundle: String) -> QueryResult {
        let script = """
        with timeout of 8 seconds
        tell application id "\(bundle)"
            try
                set playerState to (player state as text)
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                return playerState & "«|»" & trackName & "«|»" & trackArtist & "«|»" & trackAlbum
            on error
                return "stopped«|»«|»«|»"
            end try
        end tell
        end timeout
        """
        do {
            let parts = try OSAScript.run(script).components(separatedBy: "«|»")
            guard parts.count >= 4, !parts[1].isEmpty else { return .none }
            return .success(NowPlaying(app: display, bundleID: bundle,
                                       title: parts[1], artist: parts[2], album: parts[3],
                                       playing: parts[0].lowercased().contains("playing")))
        } catch OSAScript.Failure.notAuthorized {
            return .denied
        } catch {
            return .none
        }
    }

    private func command(_ verb: String) {
        guard let c = current else { return }
        _ = try? OSAScript.run("tell application id \"\(c.bundleID)\" to \(verb)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
    }

    func playPause() { command("playpause") }
    func skip(_ forward: Bool) { command(forward ? "next track" : "previous track") }
}

struct NowPlayingModule: View {
    @ObservedObject var model: NowPlayingModel

    var body: some View {
        ModuleBody {
            if let c = model.current {
                HStack(spacing: 10) {
                    Image(systemName: c.app == "Spotify" ? "music.note" : "music.note.list")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(c.artist.isEmpty ? c.app : c.artist)
                            .font(.ui(10.5)).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        control("backward.fill", 11) { model.skip(false) }
                        control(c.playing ? "pause.fill" : "play.fill", 14) { model.playPause() }
                        control("forward.fill", 11) { model.skip(true) }
                    }
                }
                .frame(maxHeight: .infinity)
            } else if model.blocked {
                ModuleNotice(icon: "lock", title: "Contrôle audio non autorisé",
                             detail: "Autorisez Cockpit à piloter Musique / Spotify dans Réglages Système › Confidentialité › Automatisation.")
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "music.note").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    Text("Rien en lecture").font(.ui(11)).foregroundStyle(Theme.textFaint)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func control(_ name: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(Theme.text)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
