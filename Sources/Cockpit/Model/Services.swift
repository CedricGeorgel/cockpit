import SwiftUI

/// Point d'entrée unique des sources de données. Chaque module observe son
/// sous-modèle ; `Services` se contente de les tenir et de lancer les
/// rafraîchissements périodiques.
final class Services: ObservableObject {
    static let shared = Services()

    let disk = DiskModel()
    let weather = WeatherModel()
    let calendar = CalendarModel()
    let todos = TodosModel()
    let news = NewsModel()
    let nowPlaying = NowPlayingModel()
    let mail = MailModel()
    let battery = BatteryModel()
    let parcels = ParcelsModel()
    let birthdays = BirthdaysModel()

    private var started = false

    private init() {}

    @MainActor
    func startAll() {
        guard !started else { return }
        started = true
        RemoteBridge.shared.start()
        UpdateChecker.shared.start()
        disk.start()
        weather.refresh()
        calendar.start()
        todos.start()
        news.refresh()
        nowPlaying.start()
        mail.start()
        battery.start()
        parcels.start()
        birthdays.start()

        CockpitStatus.shared.start()

        // Rafraîchissements légers.
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.disk.refreshVolume()
        }
        Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.weather.refresh()
        }
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.news.refresh()
        }
    }

    @MainActor
    func refreshEverything() {
        weather.refresh(); news.refresh(); mail.refreshAll(); parcels.refresh()
        calendar.reload(); todos.reload(); battery.refresh(); disk.refreshVolume()
        CockpitStatus.shared.recompute()
    }
}
