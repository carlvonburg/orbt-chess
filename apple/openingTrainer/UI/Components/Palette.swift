import SwiftUI
#if os(macOS)
import AppKit
#endif

// The app's colors, by meaning (Design/COLORS.md). Each meaning has one hue in a theme, always
// next to a symbol, text or shape; views use these roles, never a hue by name. The accent (the
// app color, system blue by default, or the Mac user's choice) is for controls and, tinted, for
// progress; it never carries another meaning.

/// A color by its meaning, resolved by the app's `Theme` where it is drawn: views say what a
/// color means (`.done`, `.attention`), the theme decides the hue, so a change of app color
/// reaches every view.
nonisolated struct ThemeColor: ShapeStyle, Hashable {
    enum Role: Hashable {
        /// Done: covered, your move, a correct answer, learned (Anki's review, young, mature).
        case done
        /// Something to do: missing coverage (gaps), a streak at risk, a leech.
        case attention
        /// New, not studied yet (Anki).
        case new
        /// Wrong, study again now (Anki's learning and relearning, Again, overdue).
        case wrong
        /// Reviewed ahead (Anki's filtered decks).
        case ahead
        /// Inactive: suspended.
        case inactive
        /// Apple's red: something failed (error messages), buttons that delete.
        case failure
        /// Study progress, tinted like an accented widget: the app color (indigo for graphite;
        /// Multicolor: green). Reviews due, mature moves (young at half).
        case progress
        /// Moves you're learning (Anki's learning and relearning): the secondary label color.
        case learning
        /// New, not studied yet: the label color (Multicolor: blue); in the studied bar the empty track.
        case unstudied
        /// Building: the covered part of a coverage bar, the app color in every theme (it
        /// belongs with the board).
        case built
        /// Gap counts: the app color (Multicolor: orange, something to do).
        case gaps
        /// A streak that is safe today: the label color (Multicolor: orange).
        case streak
    }

    let role: Role
    var alpha: Double = 1

    func opacity(_ alpha: Double) -> ThemeColor { ThemeColor(role: role, alpha: self.alpha * alpha) }

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        environment.theme.color(role).opacity(alpha).resolve(in: environment)
    }
}

extension ShapeStyle where Self == ThemeColor {
    /// Done: covered, your move, a correct answer, learned (Anki's review count, mature; young at
    /// half strength).
    static var done: ThemeColor { ThemeColor(role: .done) }
    /// Something to do: gaps, a streak at risk, a leech.
    static var attention: ThemeColor { ThemeColor(role: .attention) }
    /// New, not studied yet (Anki).
    static var new: ThemeColor { ThemeColor(role: .new) }
    /// Wrong, study again now: Again, Anki's learning and relearning (learning at half
    /// strength), overdue.
    static var wrong: ThemeColor { ThemeColor(role: .wrong) }
    /// Reviewed ahead (Anki's filtered decks).
    static var ahead: ThemeColor { ThemeColor(role: .ahead) }
    /// Inactive: suspended.
    static var inactive: ThemeColor { ThemeColor(role: .inactive) }
    /// Apple's red: error messages, buttons that delete where the destructive role can't be used.
    static var failure: ThemeColor { ThemeColor(role: .failure) }
    /// Study progress: the app color (Multicolor: green). Reviews due, mature (young at half).
    static var progress: ThemeColor { ThemeColor(role: .progress) }
    /// Moves you're learning: the secondary label color.
    static var learning: ThemeColor { ThemeColor(role: .learning) }
    /// New, not studied yet: the label color.
    static var unstudied: ThemeColor { ThemeColor(role: .unstudied) }
    /// Building: the covered part of a coverage bar, the app color in every theme.
    static var built: ThemeColor { ThemeColor(role: .built) }
    /// Gap counts: the app color (Multicolor: orange).
    static var gaps: ThemeColor { ThemeColor(role: .gaps) }
    /// A streak that is safe today: the label color (Multicolor: orange).
    static var streak: ThemeColor { ThemeColor(role: .streak) }
}

/// The colors of one app color: every meaning's hue, and the board. Each meaning has a system
/// color; when the app color has that hue (or tints the board too close to it), the meaning
/// takes a stand-in from another family, everywhere (Design/COLORS.md has the table and the
/// measurements).
nonisolated struct Theme {
    let appColor: AppColor

    func color(_ role: ThemeColor.Role) -> Color {
        switch role {
        case .done: appColor == .green ? .indigo : .green
        case .attention: [.orange, .yellow].contains(appColor) ? .purple : .orange
        case .new: appColor == .blue ? .indigo : .blue
        case .wrong: [.red, .pink].contains(appColor) ? .purple : .red
        case .ahead: .cyan
        case .inactive: .gray
        case .failure: .red
        // Multicolor keeps Anki's colors for studying: review and mature green, learning red,
        // new blue. Building keeps the app color.
        case .progress:
            switch appColor {
            case .multicolor: color(.done)
            case .graphite: .indigo
            default: appColor.tint ?? .accentColor
            }
        case .learning: appColor == .multicolor ? color(.wrong) : .secondary
        case .unstudied: appColor == .multicolor ? color(.new) : .primary
        case .built: appColor == .multicolor ? appColor.tint ?? .accentColor : color(.progress)
        case .gaps: appColor == .multicolor ? color(.attention) : color(.progress)
        case .streak: appColor == .multicolor ? color(.attention) : .primary
        }
    }

    var board: BoardTheme { BoardTheme(theme: self) }
}

nonisolated extension EnvironmentValues {
    @Entry var theme = Theme(appColor: AppColor.default.resolved)
}

/// The app's color, chosen in Settings (on the Mac first Automatic, the system accent; then
/// Multicolor, blue controls with Anki's colors for progress; then the Mac's accent colors, blue
/// first, then indigo): buttons, selection, progress and the board's tint.
nonisolated enum AppColor: String, CaseIterable, Identifiable {
    case automatic, multicolor, blue, indigo, purple, pink, red, orange, yellow, green, graphite

    static let key = "appColor"
    /// The Mac's accent on the Mac; elsewhere Multicolor.
    #if os(macOS)
    static let `default` = AppColor.automatic
    #else
    static let `default` = AppColor.multicolor
    #endif

    /// The colors Settings offers: Automatic only on the Mac, which has a system accent.
    static var choices: [AppColor] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { $0 != .automatic }
        #endif
    }

    var id: Self { self }
    var title: String { rawValue.capitalized }

    /// The color itself: Automatic is the system accent's nearest app color.
    var resolved: AppColor { self == .automatic ? .systemAccent : self }

    /// The app color nearest the Mac's accent color (System Settings › Appearance): graphite
    /// when it has almost no color, else the accent with the closest hue. Multicolor gives the
    /// app's own accent, blue. Elsewhere blue.
    static var systemAccent: AppColor {
        #if os(macOS)
        guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return .blue }
        if accent.saturationComponent < 0.25 { return .graphite }
        let accents: [(AppColor, NSColor)] = [
            (.blue, .systemBlue), (.purple, .systemPurple), (.pink, .systemPink), (.red, .systemRed),
            (.orange, .systemOrange), (.yellow, .systemYellow), (.green, .systemGreen),
        ]
        func distance(_ color: NSColor) -> CGFloat {
            let d = abs((color.usingColorSpace(.sRGB)?.hueComponent ?? 0) - accent.hueComponent)
            return min(d, 1 - d)
        }
        return accents.min { distance($0.1) < distance($1.1) }?.0 ?? .blue
        #else
        .blue
        #endif
    }

    /// The tint to set; nil for blue and Automatic, the asset catalog's accent, which a Mac
    /// user's accent color replaces. Multicolor is always blue.
    var tint: Color? {
        switch self {
        case .automatic, .blue: nil
        case .multicolor: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .graphite: .gray
        }
    }

    /// The board's tint: the app color itself (for Automatic, the system accent's nearest).
    var board: Color {
        switch self {
        case .automatic: Self.systemAccent.board
        case .multicolor: .blue
        case .indigo: .indigo
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .graphite: .gray
        }
    }

}

extension View {
    /// Applies the app color from Settings: the accent and the theme.
    func appTint() -> some View { modifier(AppTint()) }
}

private struct AppTint: ViewModifier {
    @AppStorage(AppColor.key) private var appColor = AppColor.default
    /// The system accent's app color, read again when the Mac's accent changes.
    @State private var systemAccent = AppColor.systemAccent

    func body(content: Content) -> some View {
        content
            .tint(appColor.tint)
            .environment(\.theme, Theme(appColor: appColor == .automatic ? systemAccent : appColor))
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in
                systemAccent = .systemAccent
            }
            #endif
    }
}

/// The board for a theme: content with its own colors (not the app's light or dark
/// appearance), its squares tinted toward the app color, its overlays in the theme's colors.
nonisolated struct BoardTheme {
    let theme: Theme

    var light: Color { Color("BoardLight").mix(with: theme.appColor.board, by: 0.14) }
    var dark: Color { Color("BoardDark").mix(with: theme.appColor.board, by: 0.28) }
    /// The board's ink, tinted like the progress colors: the app color mixed halfway to black,
    /// which every board shows clearly (a board swallows its own hue). Your moves, the hint,
    /// the replies you cover and, dashed, the gaps; the ✓ badge.
    var ink: Color { theme.appColor.board.mix(with: .black, by: 0.55) }
    var wrong: Color { theme.color(.wrong) }
    /// The last move and the selected square: the app color over the square (the ink for
    /// graphite, whose gray the board doesn't show).
    var lastMove: Color { theme.appColor == .graphite ? ink.opacity(0.25) : theme.appColor.board.opacity(0.5) }
    var selected: Color { theme.appColor == .graphite ? ink.opacity(0.4) : theme.appColor.board.opacity(0.75) }
    /// The engine's lines: quiet, there are often three of them.
    let engine = Color(.sRGB, red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255)
}
