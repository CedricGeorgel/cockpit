import SwiftUI

/// Fenêtre Réglages (⌘,). Regroupe ce qui était éparpillé dans les menus.
struct SettingsView: View {
    @AppStorage("cockpit.theme") private var theme = "auto"
    @AppStorage("cockpit.menubar") private var menuBar = true

    @AppStorage("cockpit.notif") private var notif = false
    @AppStorage("cockpit.notif.trips") private var notifTrips = true
    @AppStorage("cockpit.notif.parcels") private var notifParcels = true
    @AppStorage("cockpit.notif.mail") private var notifMail = true

    @State private var account = RemoteBridge.shared.accountEmail

    var body: some View {
        Form {
            Section("Apparence") {
                Picker("Thème", selection: $theme) {
                    Text("Automatique").tag("auto")
                    Text("Clair").tag("light")
                    Text("Sombre").tag("dark")
                }
            }

            Section("Barre de menus") {
                Toggle("Afficher Cockpit dans la barre de menus", isOn: $menuBar)
                Text("Statut compact toujours visible (prochain évènement, mails, trajet). Cockpit reste actif fenêtre fermée.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: menuBar) { _, on in MenuBarController.shared.setVisible(on) }

            Section("Notifications") {
                Toggle("Activer les notifications", isOn: $notif)
                if notif {
                    Toggle("Trajet dans moins de 30 min", isOn: $notifTrips)
                    Toggle("Colis en livraison / à retirer", isOn: $notifParcels)
                    Toggle("Mail important (mot-clé suivi)", isOn: $notifMail)
                }
                Text("Au plus une notification par évènement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: notif) { _, on in if on { Notifier.requestAuthorization() } }

            Section("Compte") {
                if account.isEmpty {
                    LabeledContent("État", value: "Ce Mac uniquement")
                    Button("Se connecter (sync téléphone + flotte)…") {
                        NotificationCenter.default.post(name: .cockpitOpenConnect, object: nil)
                    }
                    Text("Sans connexion, tout reste local à ce Mac. La PWA sur téléphone et le partage entre Macs demandent un compte.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Connecté", value: account)
                    Button("Se déconnecter", role: .destructive) {
                        RemoteBridge.shared.disconnect()
                        UserDefaults.standard.set(true, forKey: "cockpit.localMode")
                        account = ""
                    }
                }
            }

            Section("Prisme") {
                if PrismeAPI.isAvailable {
                    LabeledContent("Installé", value: PrismeAPI.installedVersion ?? "?")
                    Button("Ouvrir Prisme") { PrismeAPI.openApp() }
                } else {
                    Button("Télécharger Prisme") { NSWorkspace.shared.open(PrismeAPI.siteURL) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 460)
    }
}
