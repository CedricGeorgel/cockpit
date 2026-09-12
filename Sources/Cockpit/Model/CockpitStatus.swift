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

    /// Un évènement bref (nouveau mail important…) : s'affiche à la place de
    /// `menuLine` quelques secondes puis s'efface tout seul. Le persistant
    /// (compte à rebours d'un trajet/évènement/rappel) ne passe jamais par
    /// ici — un flash ne fait qu'interrompre brièvement l'affichage.
    struct Flash: Equatable { let text: String; let symbol: String }
    @Published private(set) var flash: Flash?

    private var timer: Timer?
    private var started = false
    private var seenImportantMailIDs: Set<String> = []
    private var mailSeeded = false
    private var flashQueue: [Flash] = []
    private var flashTimer: Timer?

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
        let reminders = s.todos.items
        let importantUnread = s.mail.sources
            .flatMap { s.mail.state($0.id).mails }
            .filter { !$0.seen }
        let parcels = s.parcels.parcels

        // --- ligne barre de menus : la chose la plus pressante ---
        // Persistante (reste affichée) : trajet, puis le plus proche entre un
        // évènement et un rappel à heure fixe, puis les paliers plus calmes.
        var line = ""
        var sym = "gauge.open.with.lines.needle.33percent"

        struct Candidate { let title: String; let dt: TimeInterval; let symbol: String }

        if let t = trips.compactMap({ trip -> (Trip, TimeInterval)? in
            guard let d = trip.departure else { return nil }
            let dt = d.timeIntervalSince(now)
            return (dt > -1800 && dt < 5400) ? (trip, dt) : nil
        }).min(by: { $0.1 < $1.1 }) {
            sym = t.0.mode == .flight ? "airplane" : "tram.fill"
            line = countdownLine(t.0.title.isEmpty ? "Trajet" : t.0.title, t.1)
        } else {
            var cands: [Candidate] = []
            if let e = events.first(where: {
                guard let st = $0.start, !$0.allDay else { return false }
                let dt = st.timeIntervalSince(now); return dt > -60 && dt < 2700
            }) {
                cands.append(Candidate(title: e.title, dt: e.start!.timeIntervalSince(now), symbol: "calendar"))
            }
            if let r = reminders.compactMap({ item -> Candidate? in
                guard let due = item.due else { return nil }
                let dt = due.timeIntervalSince(now)
                return (dt > -60 && dt < 2700) ? Candidate(title: item.title, dt: dt, symbol: "checklist") : nil
            }).min(by: { $0.dt < $1.dt }) {
                cands.append(r)
            }
            if let best = cands.min(by: { $0.dt < $1.dt }) {
                sym = best.symbol
                line = countdownLine(best.title, best.dt)
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
        }

        if menuLine != line { menuLine = line }
        if symbol != sym { symbol = sym }

        // --- flash éphémère : un nouveau mail important qui vient d'arriver ---
        checkNewMail(importantUnread)

        // --- notifications ---
        runNotifications(trips: trips, importantUnread: importantUnread, parcels: parcels, now: now)
    }

    /// « 45min avant TITRE », « 1h30 avant TITRE », « en cours · TITRE ».
    private func countdownLine(_ title: String, _ dt: TimeInterval) -> String {
        guard dt > 0 else { return "en cours · \(short(title))" }
        let totalMin = Int(dt / 60)
        let h = totalMin / 60, m = totalMin % 60
        let t: String
        if h > 0 && m > 0      { t = "\(h)h\(String(format: "%02d", m))" }
        else if h > 0           { t = "\(h)h" }
        else                    { t = "\(m)min" }
        return "\(t) avant \(short(title))"
    }

    /// Repère les mails importants jamais vus (pas juste « non lus ») pour les
    /// annoncer brièvement. Ne déclenche rien au tout premier passage (on ne
    /// veut pas une rafale de flashs au lancement).
    private func checkNewMail(_ importantUnread: [MailModel.Mail]) {
        let ids = Set(importantUnread.map { $0.messageID.isEmpty ? $0.id : $0.messageID })
        defer { seenImportantMailIDs = ids }
        guard mailSeeded else { mailSeeded = true; return }
        let fresh = importantUnread.filter {
            !seenImportantMailIDs.contains($0.messageID.isEmpty ? $0.id : $0.messageID)
        }
        for m in fresh.prefix(3) {   // pas de rafale si beaucoup arrivent d'un coup
            enqueueFlash(Flash(text: "\(short(m.fromName, 14)) : \(short(m.subject, 26))",
                               symbol: "envelope.fill"))
        }
    }

    private func enqueueFlash(_ f: Flash) {
        flashQueue.append(f)
        if flash == nil { popFlash() }
    }

    private func popFlash() {
        flashTimer?.invalidate()
        guard !flashQueue.isEmpty else { flash = nil; return }
        flash = flashQueue.removeFirst()
        let t = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.popFlash() }
        }
        RunLoop.main.add(t, forMode: .common)
        flashTimer = t
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
