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
                    Text("Non connecté").foregroundStyle(.secondary)
                } else {
                    LabeledContent("Connecté", value: account)
                    Button("Se déconnecter", role: .destructive) {
                        RemoteBridge.shared.disconnect(); account = ""
                    }
                }
                Text("La connexion et la synchro flotte se gèrent depuis la barre du haut (Réglages › Tableau de bord mobile).")
                    .font(.caption).foregroundStyle(.secondary)
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
