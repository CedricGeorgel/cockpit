import SwiftUI

/// Géométrie des colonnes pour une taille de canevas donnée.
struct ColumnMetrics: Equatable {
    var canvas: CGSize
    var columnCount: Int

    let outerPad: CGFloat = 14
    let colGap: CGFloat = 12
    let cardGap: CGFloat = 12

    var columnWidth: CGFloat {
        (canvas.width - 2 * outerPad - CGFloat(columnCount - 1) * colGap) / CGFloat(max(1, columnCount))
    }
    var columnHeight: CGFloat { max(120, canvas.height - 2 * outerPad) }

    func columnX(_ i: Int) -> CGFloat { outerPad + CGFloat(i) * (columnWidth + colGap) }

    static let collapsedHeight: CGFloat = 33   // hauteur d'un entête seul

    /// Hauteurs des cartes d'une colonne. Les cartes « repliées » (utiles mais
    /// vides) ne gardent que leur entête ; le reste va aux cartes déployées.
    func cardHeights(_ weights: [Double], collapsed: [Bool] = []) -> [CGFloat] {
        let n = weights.count
        guard n > 0 else { return [] }
        let isCol = { (i: Int) in collapsed.indices.contains(i) && collapsed[i] }
        let avail = columnHeight - CGFloat(n - 1) * cardGap
        let collapsedTotal = (0..<n).filter(isCol).count
        let free = avail - CGFloat(collapsedTotal) * Self.collapsedHeight
        let expandedWeight = max(0.001, (0..<n).filter { !isCol($0) }.map { weights[$0] }.reduce(0, +))
        return (0..<n).map { i in
            isCol(i) ? Self.collapsedHeight
                     : max(44, free * CGFloat(weights[i] / expandedWeight))
        }
    }

    /// Rectangle de la carte à l'indice `i` dans une colonne aux hauteurs données.
    func cardRect(col: Int, index i: Int, heights: [CGFloat]) -> CGRect {
        var y = outerPad
        for k in 0..<min(i, heights.count) { y += heights[k] + cardGap }
        let h = heights.indices.contains(i) ? heights[i] : 120
        return CGRect(x: columnX(col), y: y, width: columnWidth, height: h)
    }

    /// Colonne sous une abscisse.
    func column(atX x: CGFloat) -> Int {
        Int(((x - outerPad) / (columnWidth + colGap)).rounded(.down))
            .clamped(to: 0...(columnCount - 1))
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

// MARK: - Carte

/// Une carte de module dans une colonne. Le cadre commun : entête (poignée de
/// déplacement en mode organisation) + contenu.
struct ModuleCard<Content: View>: View {
    let kind: ModuleKind
    @ObservedObject var canvas: CanvasModel
    let metrics: ColumnMetrics
    var alert: Bool = false
    var tint: Color? = nil
    var collapsed: Bool = false
    var collapsedNote: String? = nil
    var onToggle: () -> Void = {}
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    private var isDragging: Bool { canvas.draggingKind == kind }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                Divider().overlay(Theme.hairline)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(alert ? Theme.warn.opacity(scheme == .dark ? 0.16 : 0.10)
                          : (tint?.opacity(scheme == .dark ? 0.16 : 0.12) ?? .clear)))
        )
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(isDragging ? Theme.accent.opacity(0.5) : alert ? Theme.warn.opacity(0.75) : Theme.hairline,
                          style: StrokeStyle(lineWidth: isDragging ? 1.5 : alert ? 1.5 : 1,
                                             dash: isDragging ? [5, 4] : [])))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: .black.opacity(scheme == .dark ? 0.34 : 0.10), radius: 7, y: 4)
        .opacity(isDragging ? 0.35 : 1)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: kind.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(collapsed ? Theme.textFaint : Theme.accent)
            Text(kind.title)
                .font(.ui(12, .semibold))
                .foregroundStyle(collapsed ? Theme.textDim : Theme.text)
                .lineLimit(1)
            if collapsed, let note = collapsedNote {
                Text(note).font(.ui(10)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer(minLength: 4)
            if canvas.editing {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                Button { canvas.toggleHidden(kind) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textFaint)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Retirer ce module")
            } else if !canvas.editing {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textFaint.opacity(collapsed ? 1 : 0.35))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: collapsed ? ColumnMetrics.collapsedHeight : 32)
        .background(Theme.cardHeader)
        .contentShape(Rectangle())
        .onTapGesture { if !canvas.editing { onToggle() } }
        .gesture(moveGesture, including: canvas.editing ? .all : .none)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("cockpitCanvas"))
            .onChanged { g in
                if canvas.draggingKind != kind { canvas.beginDrag(kind) }
                canvas.setDrop(Self.hitTest(g.location, kind: kind, metrics: metrics, canvas: canvas))
            }
            .onEnded { _ in canvas.endDrag() }
    }

    /// Où irait la carte si on la lâchait à `point` (colonne + index).
    static func hitTest(_ point: CGPoint, kind: ModuleKind,
                        metrics m: ColumnMetrics, canvas: CanvasModel) -> CanvasModel.DropTarget {
        let col = m.column(atX: point.x)
        let list = canvas.columns[safe: col]?.filter { $0 != kind } ?? []
        let heights = m.cardHeights(list.map { canvas.weight($0) })
        var y = m.outerPad
        for (i, h) in heights.enumerated() {
            if point.y < y + h / 2 { return .init(col: col, index: i) }
            y += h + m.cardGap
        }
        return .init(col: col, index: list.count)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Séparateur redimensionnable

struct ResizeDivider: View {
    @ObservedObject var canvas: CanvasModel
    let col: Int
    let upper: Int
    let metrics: ColumnMetrics
    @State private var hover = false

    var body: some View {
        Capsule()
            .fill(hover ? Theme.accent.opacity(0.7) : Theme.textFaint.opacity(0.35))
            .frame(width: 40, height: 4)
            .frame(width: metrics.columnWidth, height: metrics.cardGap + 6)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if !dragging { dragging = true; canvas.beginResize(col: col, upper: upper) }
                        let dw = Double(g.translation.height / metrics.columnHeight) * canvas.columnWeight(col)
                        canvas.updateResize(col: col, upper: upper, deltaWeight: dw)
                    }
                    .onEnded { _ in dragging = false; canvas.endResize() }
            )
    }

    @State private var dragging = false
}

// MARK: - Blocs partagés par les modules

/// Remplissage standard du corps d'un module.
struct ModuleBody<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Message d'état neutre (chargement, permission manquante, liste vide).
struct ModuleNotice: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.textFaint)
            Text(title)
                .font(.ui(12, .medium))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.ui(10.5))
                    .foregroundStyle(Theme.textFaint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(GhostButtonStyle())
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
