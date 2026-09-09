import SwiftUI

/// Écran plein cadre affiché tant que Cockpit n'est pas relié à un compte.
/// Sans connexion : rien ne tourne (pas de relève mail, agenda…), tout doit
/// passer par le serveur pour éviter les états divergents entre appareils.
struct SignInView: View {
    @AppStorage("cockpit.theme") private var theme = "auto"
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
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "gauge.open.with.lines.needle.33percent")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Theme.accent)
                Text("Cockpit").font(.ui(24, .semibold)).foregroundStyle(Theme.text)
                Text("Connecte-toi pour utiliser le tableau de bord. Tes appareils\npartagent alors le même état via ton serveur.")
                    .font(.ui(12)).foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

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
                        .multilineTextAlignment(.center)
                        .frame(width: 320)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    startGoogle()
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small) }
                        Text("Se connecter avec Google").font(.ui(13, .semibold))
                    }
                    .frame(width: 300)
                    .padding(.vertical, 10)
                }
                .buttonStyle(GhostButtonStyle(prominent: true))
                .disabled(busy || relay.trimmingCharacters(in: .whitespaces).isEmpty)

                DisclosureGroup(isExpanded: $showKey) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("eyJ1Ijoi…", text: $key, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                            .font(.system(size: 11, design: .monospaced))
                        Button("Connecter avec la clé") {
                            if RemoteBridge.shared.applyKey(key) { RemoteBridge.shared.syncNow() }
                            else { error = "Clé illisible." }
                        }
                        .buttonStyle(GhostButtonStyle())
                        .font(.ui(10))
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 4)
                    .frame(width: 320)
                } label: {
                    Text("J'ai une clé de connexion").font(.ui(10)).foregroundStyle(Theme.info)
                }
                .frame(width: 320)

                Spacer()
            }
            .padding(40)
        }
        .frame(minWidth: 520, minHeight: 480)
        .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
    }

    private func startGoogle() {
        busy = true; error = nil
        RemoteBridge.shared.signInWithGoogle(relay: relay) { result in
            DispatchQueue.main.async {
                busy = false
                if case .failure(let e) = result { error = e.localizedDescription }
                else { RemoteBridge.shared.syncNow() }
                // succès → l'écriture du jeton bascule RootView vers le dashboard
            }
        }
    }
}
