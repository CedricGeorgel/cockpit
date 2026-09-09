import Foundation
import AppKit
import SwiftUI

/// Ce qui compte « maintenant », condensé : alimente la barre de menus et
/// déclenche les notifications. Recalculé toutes les 20 s à partir des modèles
/// déjà chargés (aucune requête réseau).
@MainActor
final class CockpitStatus: ObservableObject {
    static let shared = CockpitStatus()

    /// Ligne courte pour la barre de menus ("" = juste l'icône).
    @Published private(set) var menuLine = ""
    /// Symbole SF pour l'icône de la barre de menus.
    @Published private(set) var symbol = "gauge.open.with.lines.needle.33percent"

    private var timer: Timer?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        recompute()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.recompute() } }
    }

    func recompute() {
        let s = Services.shared
        let now = Date()
        let cal = Calendar.current

        let trips = TripsDigest.compute(
            s.calendar.events,
            mails: s.mail.sources.flatMap { s.mail.state($0.id).mails }, now: now)
        let events = s.calendar.events
        let importantUnread = s.mail.sources
            .flatMap { s.mail.state($0.id).mails }
            .filter { !$0.seen }
        let parcels = s.parcels.parcels

        // --- ligne barre de menus : la chose la plus pressante ---
        var line = ""
        var sym = "gauge.open.with.lines.needle.33percent"

        if let t = trips.compactMap({ trip -> (Trip, TimeInterval)? in
            guard let d = trip.departure else { return nil }
            let dt = d.timeIntervalSince(now)
            return (dt > -1800 && dt < 5400) ? (trip, dt) : nil
        }).min(by: { $0.1 < $1.1 }) {
            sym = t.0.mode == .flight ? "airplane" : "tram.fill"
            line = t.0.departure.map { Fmt.shortTime($0) } ?? ""
            let m = Int(t.1 / 60)
            line += m > 0 ? " · dans \(m) min" : " · en cours"
        } else if let e = events.first(where: {
            guard let st = $0.start, !$0.allDay else { return false }
            let dt = st.timeIntervalSince(now); return dt > 0 && dt < 2700
        }) {
            sym = "calendar"
            let m = Int((e.start!.timeIntervalSince(now)) / 60)
            line = "\(short(e.title)) · dans \(m) min"
        } else if !importantUnread.isEmpty {
            sym = "envelope.fill"
            line = "\(importantUnread.count)"
        } else if let p = parcels.first(where: { $0.status == .outForDelivery || $0.status == .readyForPickup }) {
            sym = "shippingbox.fill"
            line = p.status == .outForDelivery ? "en livraison" : "à retirer"
        } else if let e = events.first(where: {
            guard let st = $0.start, !$0.allDay else { return false }
            return cal.isDateInToday(st) && st > now
        }) {
            sym = "calendar"
            line = "\(short(e.title)) \(Fmt.shortTime(e.start!))"
        }

        if menuLine != line { menuLine = line }
        if symbol != sym { symbol = sym }

        // --- notifications ---
        runNotifications(trips: trips, importantUnread: importantUnread, parcels: parcels, now: now)
    }

    private func runNotifications(trips: [Trip], importantUnread: [MailModel.Mail],
                                  parcels: [ParcelScanner.Parcel], now: Date) {
        guard Notifier.masterEnabled else { return }

        if Notifier.categoryEnabled("cockpit.notif.trips") {
            var live = Set<String>()
            for t in trips {
                guard let d = t.departure else { continue }
                let dt = d.timeIntervalSince(now)
                let id = "trip-\(t.id)"
                if dt > 0 && dt < 1800 {
                    live.insert(id)
                    Notifier.fireOnce(id: id, title: "Départ dans \(Int(dt / 60)) min",
                                      body: t.title.isEmpty ? "Trajet" : t.title)
                }
            }
            Notifier.forget(prefix: "trip-", keeping: live)
        }

        if Notifier.categoryEnabled("cockpit.notif.parcels") {
            for p in parcels {
                let tag: String?
                switch p.status {
                case .outForDelivery: tag = "livraison"
                case .readyForPickup: tag = "retrait"
                case .issue:          tag = "incident"
                default:              tag = nil
                }
                guard let tag else { continue }
                let title = p.status == .outForDelivery ? "Colis en livraison"
                    : p.status == .readyForPickup ? "Colis à retirer" : "Problème de livraison"
                Notifier.fireOnce(id: "parcel-\(p.id)-\(tag)", title: title,
                                  body: "\(p.merchant) · \(p.carrier.display)")
            }
        }

        if Notifier.categoryEnabled("cockpit.notif.mail") {
            let cutoff = now.addingTimeInterval(-3 * 3600)
            for m in importantUnread where m.reason == .keyword && m.date > cutoff {
                Notifier.fireOnce(id: "mail-\(m.messageID)", title: "Mail important",
                                  body: "\(m.fromName) — \(short(m.subject, 60))")
            }
        }
    }

    private func short(_ s: String, _ n: Int = 22) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}
