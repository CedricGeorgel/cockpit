import SwiftUI

/// Premier lancement : choisir entre « ce Mac uniquement » (aucun serveur) et se
/// connecter avec Google pour synchroniser téléphone + autres Macs.
struct SignInView: View {
    @AppStorage("cockpit.theme") private var theme = "auto"
    @AppStorage("cockpit.localMode") private var localMode = false

    @State private var showConnect = false
    @State private var relay = {
        let s = RemoteBridge.shared.relayURLString
        return s.isEmpty ? "dashboard.caadesign.fr" : s
    }()
    @State private var key = ""
    @State private var showKey = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "gauge.open.with.lines.needle.33percent")
                    .font(.system(size: 42)).foregroundStyle(Theme.accent)
                Text("Cockpit").font(.ui(24, .semibold)).foregroundStyle(Theme.text)
                Text("Ton tableau de bord : agenda, mails importants, colis,\ntrajets, météo, à faire, bloc-notes.")
                    .font(.ui(11.5)).foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)

                if showConnect { connectPane } else { choicePane }

                Spacer()
            }
            .padding(40)
        }
        .frame(minWidth: 520, minHeight: 500)
        .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
    }

    // MARK: Choix

    private var choicePane: some View {
        VStack(spacing: 10) {
            Button {
                localMode = true          // bascule RootView vers le tableau de bord
            } label: {
                VStack(spacing: 2) {
                    Text("Commencer").font(.ui(13, .semibold))
                    Text("ce Mac uniquement, aucun compte").font(.ui(9)).opacity(0.8)
                }
                .frame(width: 300).padding(.vertical, 9)
            }
            .buttonStyle(GhostButtonStyle(prominent: true))

            Button {
                showConnect = true
            } label: {
                VStack(spacing: 2) {
                    Text("Se connecter avec Google").font(.ui(12, .medium))
                    Text("pour synchroniser avec le téléphone et d'autres Macs").font(.ui(9)).opacity(0.75)
                }
                .frame(width: 300).padding(.vertical, 8)
            }
            .buttonStyle(GhostButtonStyle())

            Text("Tu pourras te connecter plus tard depuis les Réglages.")
                .font(.ui(9)).foregroundStyle(Theme.textFaint).padding(.top, 2)
        }
    }

    // MARK: Connexion

    private var connectPane: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Adresse du relais")
                TextField("dashboard.exemple.fr", text: $relay)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disableAutocorrection(true)
            }
            .frame(width: 320)

            if let error {
                Text(error).font(.ui(10.5)).foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center).frame(width: 320)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button { startGoogle() } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text("Se connecter avec Google").font(.ui(13, .semibold))
                }
                .frame(width: 300).padding(.vertical, 10)
            }
            .buttonStyle(GhostButtonStyle(prominent: true))
            .disabled(busy || relay.trimmingCharacters(in: .whitespaces).isEmpty)

            DisclosureGroup(isExpanded: $showKey) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("eyJ1Ijoi…", text: $key, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...4)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Connecter avec la clé") {
                        if RemoteBridge.shared.applyKey(key) { RemoteBridge.shared.syncNow() }
                        else { error = "Clé illisible." }
                    }
                    .buttonStyle(GhostButtonStyle()).font(.ui(10))
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 4).frame(width: 320)
            } label: {
                Text("J'ai une clé de connexion").font(.ui(10)).foregroundStyle(Theme.info)
            }
            .frame(width: 320)

            Button("Retour") { showConnect = false; error = nil }
                .buttonStyle(.plain).font(.ui(10)).foregroundStyle(Theme.textFaint)
        }
    }

    private func startGoogle() {
        busy = true; error = nil
        RemoteBridge.shared.signInWithGoogle(relay: relay) { result in
            DispatchQueue.main.async {
                busy = false
                if case .failure(let e) = result { error = e.localizedDescription }
                else { localMode = false; RemoteBridge.shared.syncNow() }
            }
        }
    }
}
