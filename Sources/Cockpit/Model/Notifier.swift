import Foundation
import UserNotifications
import AppKit

/// Notifications système, parcimonieuses : au plus une par évènement.
/// Opt-in (réglage `cockpit.notif`), autorisation demandée à l'activation.
enum Notifier {

    static var masterEnabled: Bool { UserDefaults.standard.bool(forKey: "cockpit.notif") }
    static func categoryEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// À appeler quand l'utilisateur active les notifications.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Envoie une notification si son `id` n'a jamais été envoyé.
    /// (`id` stable par évènement → pas de répétition.)
    static func fireOnce(id: String, title: String, body: String) {
        guard masterEnabled else { return }
        var sent = Set(UserDefaults.standard.stringArray(forKey: firedKey) ?? [])
        guard !sent.contains(id) else { return }
        sent.insert(id)
        UserDefaults.standard.set(Array(sent.suffix(400)), forKey: firedKey)

        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// Oublie les `id` d'entités disparues pour qu'un futur retour re-notifie.
    static func forget(prefix: String, keeping liveIDs: Set<String>) {
        var sent = Set(UserDefaults.standard.stringArray(forKey: firedKey) ?? [])
        sent = sent.filter { !$0.hasPrefix(prefix) || liveIDs.contains($0) }
        UserDefaults.standard.set(Array(sent), forKey: firedKey)
    }

    private static let firedKey = "cockpit.notif.fired.v1"
}
