import SwiftUI
import AppKit

/// Couleur qui suit l'apparence effective de la vue.
/// Reprise de Prisme : chaque palette (clair / sombre) est choisie pour son
/// fond, pas obtenue par inversion mécanique.
func dynamicColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

/// Couleur résolue pour une apparence donnée. `Canvas` ne résout pas les
/// couleurs dynamiques avec l'apparence de la vue : tout ce qui est peint
/// passe par ici, avec le thème transmis explicitement.
func resolvedColor(light: NSColor, dark: NSColor, scheme: ColorScheme) -> Color {
    Color(nsColor: scheme == .dark ? dark : light)
}

enum Theme {
    // MARK: Surfaces et texte

    static let bg = dynamicColor(light: rgb(0.945, 0.953, 0.969),   // #f1f3f7
                                 dark:  rgb(0.086, 0.096, 0.114))    // #16181d
    static let bgElevated = dynamicColor(light: rgb(1, 1, 1),
                                         dark:  rgb(0.110, 0.122, 0.145))
    static let panel = dynamicColor(light: rgb(0.925, 0.933, 0.949),
                                    dark:  rgb(0.129, 0.141, 0.169))
    /// Fond d'une carte de module, un cran au-dessus du fond de fenêtre.
    static let card = dynamicColor(light: rgb(1, 1, 1),
                                   dark:  rgb(0.125, 0.137, 0.163))
    static let cardHeader = dynamicColor(light: rgb(0.965, 0.972, 0.984),
                                         dark:  rgb(0.157, 0.171, 0.204))

    static let hairline = dynamicColor(light: NSColor.black.withAlphaComponent(0.09),
                                       dark:  NSColor.white.withAlphaComponent(0.07))
    static let stroke = dynamicColor(light: NSColor.black.withAlphaComponent(0.16),
                                     dark:  NSColor.white.withAlphaComponent(0.12))

    static let text = dynamicColor(light: rgb(0.106, 0.118, 0.141),
                                   dark:  rgb(0.918, 0.933, 0.960))
    static let textDim = dynamicColor(light: rgb(0.337, 0.369, 0.420),
                                      dark:  rgb(0.596, 0.639, 0.706))
    static let textFaint = dynamicColor(light: rgb(0.545, 0.580, 0.635),
                                        dark:  rgb(0.400, 0.435, 0.494))

    static let accent = dynamicColor(light: rgb(0.043, 0.545, 0.361),   // #0b8b5c
                                     dark:  rgb(0.290, 0.780, 0.560))
    static let warn = dynamicColor(light: rgb(0.761, 0.290, 0.075),
                                   dark:  rgb(0.925, 0.478, 0.310))
    static let danger = dynamicColor(light: rgb(0.843, 0.153, 0.153),   // #d72727
                                     dark:  rgb(1.000, 0.376, 0.361))
    static let info = dynamicColor(light: rgb(0.176, 0.404, 0.741),
                                   dark:  rgb(0.451, 0.647, 0.965))
}

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func num(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Fond de fenêtre : dégradé très doux, pour éviter l'aplat mort.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.bg
            RadialGradient(
                colors: [Color.white.opacity(scheme == .dark ? 0.045 : 0.60), .clear],
                center: .init(x: 0.30, y: 0.14), startRadius: 40, endRadius: 820
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Boutons

struct GhostButtonStyle: ButtonStyle {
    var prominent = false
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12, .medium))
            .foregroundStyle(prominent ? Color.white.opacity(0.95) : Theme.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent
                          ? AnyShapeStyle(Theme.accent.opacity(hover ? 1 : 0.92))
                          : AnyShapeStyle(Color.primary.opacity(hover ? 0.10 : 0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: prominent ? 0 : 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Entête de section : petites capitales espacées.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.ui(10, .semibold))
            .foregroundStyle(Theme.textFaint)
            .textCase(.uppercase)
            .kerning(0.6)
    }
}

// MARK: - Formatage

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useMB, .useTB]
        return f.string(fromByteCount: n)
    }

    static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func currency(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "fr_FR")
        f.currencyCode = "EUR"
        f.maximumFractionDigits = amount.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return f.string(from: amount as NSNumber) ?? String(format: "%.2f €", amount)
    }

    static func relday(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "aujourd'hui" }
        if cal.isDateInTomorrow(date) { return "demain" }
        if cal.isDateInYesterday(date) { return "hier" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }
}
