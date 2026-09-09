import SwiftUI
import AppKit

struct DashboardView: View {
    @StateObject private var canvas = CanvasModel()
    @StateObject private var services = Services.shared
    @ObservedObject private var parcelsModel = Services.shared.parcels
    @ObservedObject private var nowPlaying = Services.shared.nowPlaying
    @ObservedObject private var battery = Services.shared.battery
    @ObservedObject private var mail = Services.shared.mail
    @ObservedObject private var calendar = Services.shared.calendar
    @ObservedObject private var weather = Services.shared.weather
    @ObservedObject private var news = Services.shared.news
    @ObservedObject private var todos = Services.shared.todos
    @ObservedObject private var update = UpdateChecker.shared
    @AppStorage("cockpit.theme") private var theme = "auto"   // auto | light | dark

    /// Priment sur le repli automatique (le temps de la session).
    @State private var manualExpand: Set<ModuleKind> = []
    @State private var manualCollapse: Set<ModuleKind> = []
    @State private var scratchEmpty = ScratchStore.load().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    /// Force la ré-évaluation de ce qui dépend de l'heure (trajet parti / arrivé, alertes).
    @State private var clockTick = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = clockTick   // dépendance : body se rejoue toutes les 30 s
        return ZStack {
            AppBackground()
            VStack(spacing: 0) {
                TopBar(canvas: canvas, theme: $theme)
                ForEach(update.available) { up in
                    UpdateBanner(update: up).id("\(up.kind.rawValue)-\(up.version)")
                }
                canvasArea
            }
        }
        .frame(minWidth: 940, minHeight: 640)
        .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
        .onReceive(clock) { clockTick = $0 }
        .onAppear { services.startAll() }
        .onReceive(NotificationCenter.default.publisher(for: .cockpitScratchpadChanged)) { _ in
            scratchEmpty = ScratchStore.load().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onReceive(NotificationCenter.default.publisher(for: .cockpitSettingsImported)) { _ in
            scratchEmpty = ScratchStore.load().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onChange(of: quietSet) { old, new in
            // quand l'état « calme » d'une carte change, on repasse en automatique
            let flipped = old.symmetricDifference(new)
            manualExpand.subtract(flipped)
            manualCollapse.subtract(flipped)
        }
    }

    private var quietSet: Set<ModuleKind> { Set(ModuleKind.allCases.filter(quiet)) }

    private var canvasArea: some View {
        GeometryReader { geo in
            let m = ColumnMetrics(canvas: geo.size, columnCount: canvas.columnCount)
            ZStack(alignment: .topLeading) {
                // Colonnes de fond, visibles en mode organisation.
                if canvas.editing {
                    ForEach(0..<canvas.columnCount, id: \.self) { col in
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.025))
                            .frame(width: m.columnWidth, height: m.columnHeight)
                            .offset(x: m.columnX(col), y: m.outerPad)
                    }
                }

                cards(m)

                if canvas.draggingKind != nil, let d = canvas.drop {
                    dropIndicator(m, d)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(name: "cockpitCanvas")
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: hiddenSignature)
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: weather.detailsOpen)
        }
        .clipped()
    }

    /// Change dès qu'une carte s'affiche/se replie, pour animer le réagencement.
    private var hiddenSignature: [String] {
        ModuleKind.allCases.map { "\($0.rawValue)\(hasContent($0) ? 1 : 0)\(collapsed($0) ? 1 : 0)" }
    }

    // MARK: Repli des cartes « utiles mais calmes »

    private func quiet(_ kind: ModuleKind) -> Bool {
        switch kind {
        case .mail:
            let m = mail.sources.flatMap { mail.state($0.id).mails }
            return !m.isEmpty && m.allSatisfy(\.seen)
        case .jobs:
            let work = mail.sources.flatMap { mail.state($0.id).mails }.filter { $0.reason == .work }
            return !work.isEmpty && work.allSatisfy(\.seen)
        case .calendar:
            let cal = Calendar.current
            return !calendar.events.contains { e in
                guard let s = e.start else { return e.allDay }
                return cal.isDateInToday(s) && (e.end ?? s) > Date().addingTimeInterval(-1800)
            }
        case .todos:      return todos.items.isEmpty
        case .scratchpad: return scratchEmpty
        case .news:       return news.allRead || news.nothingFresh
        default:          return false
        }
    }

    private func collapsed(_ kind: ModuleKind) -> Bool {
        guard !canvas.editing else { return false }
        if manualCollapse.contains(kind) { return true }
        if manualExpand.contains(kind) { return false }
        return quiet(kind)
    }

    private func toggleCollapse(_ kind: ModuleKind) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            if collapsed(kind) { manualExpand.insert(kind); manualCollapse.remove(kind) }
            else { manualCollapse.insert(kind); manualExpand.remove(kind) }
        }
    }

    private func collapsedNote(_ kind: ModuleKind) -> String? {
        if quiet(kind) {
            switch kind {
            case .mail:       return "tout lu"
            case .jobs:       return "à jour"
            case .calendar:   return "rien aujourd'hui"
            case .scratchpad: return "vide"
            case .news:       return news.allRead ? "tout lu" : "rien de neuf"
            default:          return nil
            }
        }
        // Repliée à la main mais active : un compteur discret.
        switch kind {
        case .mail:
            let n = mail.sources.flatMap { mail.state($0.id).mails }.filter { !$0.seen }.count
            return n > 0 ? "\(n) non lus" : nil
        case .todos:
            return todos.items.isEmpty ? nil : "\(todos.items.count)"
        case .news:
            let n = news.items.filter { !news.read.contains($0.link?.absoluteString ?? "") }.count
            return n > 0 ? "\(n) à lire" : nil
        case .calendar:
            let cal = Calendar.current
            let n = calendar.events.filter { $0.start.map { cal.isDateInToday($0) } ?? $0.allDay }.count
            return n > 0 ? "\(n) aujourd'hui" : nil
        default:
            return nil
        }
    }

    /// Un module « à contenu » ne s'affiche que s'il a quelque chose à montrer
    /// (hors mode organisation, où tout reste visible pour l'agencement).
    private func hasContent(_ kind: ModuleKind) -> Bool {
        switch kind {
        case .parcels:    return !parcelsModel.parcels.isEmpty
        case .nowPlaying: return nowPlaying.current != nil
        case .battery:    return battery.mac != nil || !battery.devices.isEmpty || !battery.fleetMacs.isEmpty
        case .trips:      return !tripsList.isEmpty
        case .jobs:       return !JobsDigest.compute(mail.sources.flatMap { mail.state($0.id).mails }).isEmpty
        default:          return true
        }
    }

    private func displayedKinds(_ col: Int) -> [ModuleKind] {
        (canvas.columns[safe: col] ?? []).filter { canvas.editing || hasContent($0) }
    }

    /// Teinte de fond façon météo.
    private func tint(_ kind: ModuleKind) -> Color? {
        guard kind == .weather, let s = weather.snapshot else { return nil }
        return wmoTint(s.code)
    }

    private var tripsList: [Trip] {
        TripsDigest.compute(calendar.events, mails: mail.sources.flatMap { mail.state($0.id).mails })
    }

    /// Une carte passe en alerte (bordure orange) : départ dans moins d'1 h (pas encore parti).
    private func alerting(_ kind: ModuleKind) -> Bool {
        guard kind == .trips, !canvas.editing else { return false }
        return tripsList.contains {
            guard let dep = $0.departure else { return false }
            let dt = dep.timeIntervalSinceNow
            return dt > 0 && dt < 3600
        }
    }

    /// Alerte renforcée (rouge vif) : départ dans moins de 30 minutes.
    private func urgentAlerting(_ kind: ModuleKind) -> Bool {
        guard kind == .trips, !canvas.editing else { return false }
        return tripsList.contains {
            guard let dep = $0.departure else { return false }
            let dt = dep.timeIntervalSinceNow
            return dt > 0 && dt < 1800
        }
    }

    @ViewBuilder
    private func cards(_ m: ColumnMetrics) -> some View {
        ForEach(0..<canvas.columnCount, id: \.self) { col in
            let kinds = displayedKinds(col)
            let heights = m.cardHeights(kinds.map { canvas.weight($0) },
                                        collapsed: kinds.map { collapsed($0) })
            ForEach(Array(kinds.enumerated()), id: \.element) { i, kind in
                let r = m.cardRect(col: col, index: i, heights: heights)
                ModuleCard(kind: kind, canvas: canvas, metrics: m,
                           alert: alerting(kind), urgent: urgentAlerting(kind), tint: tint(kind),
                           collapsed: collapsed(kind), collapsedNote: collapsedNote(kind),
                           onToggle: { toggleCollapse(kind) }) {
                    ModuleHost(kind: kind, services: services)
                }
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .zIndex(canvas.draggingKind == kind ? 5 : 0)
                .animation(.spring(response: 0.30, dampingFraction: 0.85), value: r)

                if canvas.editing, i < kinds.count - 1 {
                    let below = m.cardRect(col: col, index: i, heights: heights)
                    ResizeDivider(canvas: canvas, col: col, upper: i, metrics: m)
                        .offset(x: below.minX, y: below.maxY + m.cardGap / 2 - (m.cardGap + 6) / 2)
                        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: heights)
                }
            }
        }
    }

    /// Rectangle translucide montrant la place exacte que prendra la carte.
    private func dropIndicator(_ m: ColumnMetrics, _ d: CanvasModel.DropTarget) -> some View {
        let r = indicatorRect(m, d)
        return RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Theme.accent.opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [7, 4])))
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .animation(.spring(response: 0.20, dampingFraction: 0.82), value: d)
            .allowsHitTesting(false)
    }

    private func indicatorRect(_ m: ColumnMetrics, _ d: CanvasModel.DropTarget) -> CGRect {
        guard let dragged = canvas.draggingKind else { return .zero }
        var list = (canvas.columns[safe: d.col] ?? []).filter { $0 != dragged }
        let idx = min(max(0, d.index), list.count)
        list.insert(dragged, at: idx)
        let heights = m.cardHeights(list.map { canvas.weight($0) })
        return m.cardRect(col: d.col, index: idx, heights: heights)
    }
}

struct UpdateBanner: View {
    let update: UpdateChecker.Available
    @ObservedObject private var checker = UpdateChecker.shared
    @State private var dismissed = false

    private var busy: Bool { checker.downloading.contains(update.kind) }

    var body: some View {
        if !dismissed {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                Text("\(update.kind.label) \(update.version) est disponible" + (update.notes.isEmpty ? "" : " · \(update.notes)"))
                    .font(.ui(11, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 8)
                Button(busy ? "Téléchargement…" : "Télécharger") {
                    UpdateChecker.shared.openDownload(update.kind)
                }
                .buttonStyle(GhostButtonStyle(prominent: true))
                .disabled(busy)
                Button { dismissed = true } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textFaint)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Theme.card)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }
}

struct TopBar: View {
    @ObservedObject var canvas: CanvasModel
    @Binding var theme: String
    @State private var now = Date()
    @State private var showMobile = false
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private func cycleTheme() {
        theme = theme == "auto" ? "light" : theme == "light" ? "dark" : "auto"
    }
    private var themeIcon: String {
        theme == "light" ? "sun.max.fill" : theme == "dark" ? "moon.fill" : "circle.lefthalf.filled"
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                Text("Cockpit")
                    .font(.ui(13, .semibold))
                    .foregroundStyle(Theme.text)
            }
            Divider().frame(height: 15).overlay(Theme.hairline)
            Text(dateLine)
                .font(.ui(12))
                .foregroundStyle(Theme.textDim)

            Spacer(minLength: 12)

            if canvas.editing {
                Picker("Colonnes", selection: Binding(
                    get: { canvas.columnCount },
                    set: { canvas.setColumnCount($0) })) {
                    Text("3").tag(3)
                    Text("4").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Menu {
                    ForEach(ModuleKind.allCases) { k in
                        let shown = !canvas.hidden.contains(k)
                        Button {
                            if !shown { canvas.toggleHidden(k) }
                        } label: {
                            Label(k.title, systemImage: shown ? "checkmark" : "plus")
                        }.disabled(shown)
                    }
                    Divider()
                    Button("Tableau de bord mobile…") { showMobile = true }
                    Button("Réinitialiser la disposition", role: .destructive) { canvas.reset() }
                } label: {
                    Label("Modules", systemImage: "square.grid.2x2")
                }
                .menuStyle(.button)
                .buttonStyle(GhostButtonStyle())
                .fixedSize()
            }

            Button { cycleTheme() } label: {
                Image(systemName: themeIcon).font(.system(size: 12))
            }
            .buttonStyle(GhostButtonStyle())
            .help("Thème : \(theme == "auto" ? "automatique" : theme == "light" ? "clair" : "sombre")")

            Button {
                canvas.cancelDrag()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    canvas.editing.toggle()
                }
                canvas.save()
            } label: {
                Label(canvas.editing ? "Terminé" : "Réglages",
                      systemImage: canvas.editing ? "checkmark" : "slider.horizontal.3")
            }
            .buttonStyle(GhostButtonStyle(prominent: canvas.editing))
        }
        .sheet(isPresented: $showMobile) { MobileSyncSheet() }
        .padding(.horizontal, 16)
        .padding(.leading, 62)
        .padding(.vertical, 9)
        .background(
            Rectangle().fill(Theme.bgElevated.opacity(0.7))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        )
        .onReceive(clock) { now = $0 }
    }

    private var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM · HH:mm"
        return f.string(from: now).capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// Fabrique la vue d'un module à partir de son type.
struct ModuleHost: View {
    let kind: ModuleKind
    @ObservedObject var services: Services

    var body: some View {
        switch kind {
        case .disk:       DiskModule(model: services.disk)
        case .calendar:   CalendarModule(model: services.calendar)
        case .weather:    WeatherModule(model: services.weather)
        case .scratchpad: ScratchpadModule()
        case .callTime:   CallTimeModule()
        case .todos:      TodosModule(model: services.todos)
        case .news:       NewsModule(model: services.news)
        case .nowPlaying: NowPlayingModule(model: services.nowPlaying)
        case .mail:       MailModule(model: services.mail)
        case .battery:    BatteryModule(model: services.battery)
        case .jobs:       JobsModule(mail: services.mail)
        case .parcels:    ParcelsModule(model: services.parcels)
        case .trips:      TripsModule(calendar: services.calendar, mail: services.mail)
        }
    }
}
