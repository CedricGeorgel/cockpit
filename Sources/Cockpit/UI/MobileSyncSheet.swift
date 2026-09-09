import SwiftUI

/// Connexion du tableau de bord mobile. On se connecte avec Google : le relais
/// vérifie l'identité et renvoie un jeton de session. La PWA utilise le même
/// compte Google. Cockpit publie ensuite l'instantané et relève les actions.
struct MobileSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var relay = {
        let s = RemoteBridge.shared.relayURLString
        return s.isEmpty ? "dashboard.caadesign.fr" : s
    }()
    @State private var key = ""
    @State private var showKey = false
    @State private var busy = false
    @State private var error: String?
    @State private var connected = RemoteBridge.shared.isConfigured
    @State private var email = RemoteBridge.shared.accountEmail

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3").font(.system(size: 15)).foregroundStyle(Theme.accent)
                Text("Tableau de bord mobile").font(.ui(14, .semibold)).foregroundStyle(Theme.text)
            }

            if connected {
                connectedBody
            } else {
                setupBody
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    // MARK: Connecté

    @ViewBuilder private var connectedBody: some View {
        Label(email.isEmpty ? "Connecté." : "Connecté, \(email)", systemImage: "checkmark.circle.fill")
            .font(.ui(11)).foregroundStyle(Theme.accent)
        Text("Ce Mac publie son tableau de bord vers ton compte. Ouvre la PWA et connecte-toi avec le même compte Google pour le consulter. Plusieurs Macs peuvent alimenter le même tableau.")
            .font(.ui(10.5)).foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)

        Toggle(isOn: Binding(
            get: { RemoteBridge.shared.executesCommands },
            set: { RemoteBridge.shared.executesCommands = $0 })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Cet appareil exécute les actions du mobile").font(.ui(11))
                Text("À décocher sur les Macs secondaires (évite les doublons).")
                    .font(.ui(9)).foregroundStyle(Theme.textFaint)
            }
        }
        .toggleStyle(.checkbox)

        HStack {
            Spacer()
            Button("Déconnecter", role: .destructive) {
                RemoteBridge.shared.disconnect()
                connected = false; email = ""; key = ""
            }
            .buttonStyle(GhostButtonStyle())
            Button("Fermer") { dismiss() }.buttonStyle(GhostButtonStyle(prominent: true))
        }
    }

    // MARK: Connexion

    @ViewBuilder private var setupBody: some View {
        Text("Connecte-toi avec Google, ici et dans la PWA sur ton téléphone : les deux verront le même tableau de bord.")
            .font(.ui(10.5)).foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Adresse du relais")
            TextField("dashboard.exemple.fr", text: $relay)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .disableAutocorrection(true)
        }

        if let error {
            Text(error).font(.ui(10)).foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Annuler") { dismiss() }.buttonStyle(GhostButtonStyle())
            Button("Se connecter avec Google") { startGoogle() }
                .buttonStyle(GhostButtonStyle(prominent: true))
                .disabled(busy || relay.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        Divider().padding(.vertical, 2)

        DisclosureGroup(isExpanded: $showKey) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ancienne méthode : colle une clé de connexion générée par la PWA.")
                    .font(.ui(9.5)).foregroundStyle(Theme.textFaint)
                TextField("eyJ1Ijoi…", text: $key, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .font(.system(size: 11, design: .monospaced))
                HStack {
                    Spacer()
                    Button("Connecter avec la clé") {
                        if RemoteBridge.shared.applyKey(key) {
                            RemoteBridge.shared.syncNow()
                            connected = true; error = nil
                        } else {
                            error = "Clé illisible. Recopie-la entièrement depuis la PWA."
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .font(.ui(10))
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("J'ai une clé de connexion").font(.ui(10)).foregroundStyle(Theme.info)
        }
    }

    private func startGoogle() {
        busy = true; error = nil
        RemoteBridge.shared.signInWithGoogle(relay: relay) { result in
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let e):
                    email = e
                    connected = true
                    RemoteBridge.shared.syncNow()
                case .failure(let err):
                    error = err.localizedDescription
                }
            }
        }
    }
}
