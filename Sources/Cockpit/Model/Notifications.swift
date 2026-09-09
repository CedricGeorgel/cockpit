import Foundation

extension Notification.Name {
    /// Postée quand des réglages ont été importés depuis le relais : les modules
    /// doivent relire leur configuration (bloc-notes, ville météo, flux, contacts).
    static let cockpitSettingsImported = Notification.Name("cockpit.settings.imported")

    /// Postée quand `RemoteBridge` a récupéré un nouvel état de la flotte.
    static let cockpitFleetUpdated = Notification.Name("cockpit.fleet.updated")

    /// Postée quand un réglage local synchronisable a changé (à pousser vers le relais).
    static let cockpitLocalSettingChanged = Notification.Name("cockpit.setting.changed")
}
