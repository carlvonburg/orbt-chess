import SwiftUI
#if os(macOS)
import AppKit
#endif

// The app's colors, by meaning (Design/COLORS.md). Views name a meaning (`ThemeColor`), never a
// hue; the theme of the app color resolves it, always next to a symbol, text or shape.
// Multicolor uses Anki's and Apple's colors for meanings; every other app color is tinted like
// Apple's accented widgets: the app color, the label colors, and red for wrong.

/// A color by its meaning, resolved by the app's `Theme` where it is drawn: views say what a
/// color means (`.learned`, `.todo`), the theme decides the hue, so a change of app color
/// reaches every view.
nonisolated struct ThemeColor: ShapeStyle, Hashable {
    enum Role: Hashable {
        /// Building: the covered part of coverage bars, your saved moves, transpositions,
        /// "Coverage target reached". The app color in every theme (it belongs with the board).
        case built
        /// Learned: reviews due, Anki's young (lighter) and mature, studied today.
        case learned
        /// Being learned: Anki's learning (lighter) and relearning.
        case learning
        /// New, not studied yet (Anki).
        case new
        /// Something to do: gaps, a missing move of yours, the streak, a leech, your alternative.
        case todo
        /// A correct answer: ✓, "Correct", correct %, Good.
        case correct
        /// A wrong answer: ✕, "Not quite", Again, overdue.
        case wrong
        /// Apple's red: something failed (error messages), buttons that delete.
        case failure
        /// Reviewed ahead (Anki's filtered decks).
        case ahead
        /// Inactive: suspended.
        case inactive
    }

    let role: Role
    var alpha: Double = 1
    /// How far the color is mixed toward white: a lighter shade of the same meaning (young
    /// next to mature).
    var lightening: Double = 0

    func opacity(_ alpha: Double) -> ThemeColor { ThemeColor(role: role, alpha: self.alpha * alpha, lightening: lightening) }
    /// A lighter shade of the same color, in light and dark appearance alike.
    func lighter(_ amount: Double = 0.45) -> ThemeColor { ThemeColor(role: role, alpha: alpha, lightening: amount) }

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        // On a selected row (the Mac sidebar's accent fill) colored details turn white, like
        // Apple's own styles; lighter shades and learning stay apart by strength.
        if environment.backgroundProminence == .increased {
            let strength = role == .learning ? 0.55 : lightening > 0 ? 0.75 : 1
            return Color.white.opacity(alpha * strength).resolve(in: environment)
        }
        var color = environment.theme.color(role)
        if lightening > 0 { color = color.mix(with: .white, by: lightening) }
        return color.opacity(alpha).resolve(in: environment)
    }
}

extension ShapeStyle where Self == ThemeColor {
    /// Building: coverage bars, saved moves, transpositions. The app color.
    static var built: ThemeColor { ThemeColor(role: .built) }
    /// Learned: reviews due, mature (young: `.learned.lighter()`), studied today.
    static var learned: ThemeColor { ThemeColor(role: .learned) }
    /// Being learned: Anki's relearning (learning: `.learning.lighter()`).
    static var learning: ThemeColor { ThemeColor(role: .learning) }
    /// New, not studied yet (Anki).
    static var new: ThemeColor { ThemeColor(role: .new) }
    /// Something to do: gaps, a missing move, the streak, a leech.
    static var todo: ThemeColor { ThemeColor(role: .todo) }
    /// A correct answer.
    static var correct: ThemeColor { ThemeColor(role: .correct) }
    /// A wrong answer, Again, overdue.
    static var wrong: ThemeColor { ThemeColor(role: .wrong) }
    /// Apple's red: error messages, buttons that delete where the destructive role can't be used.
    static var failure: ThemeColor { ThemeColor(role: .failure) }
    /// Reviewed ahead (Anki's filtered decks).
    static var ahead: ThemeColor { ThemeColor(role: .ahead) }
    /// Inactive: suspended.
    static var inactive: ThemeColor { ThemeColor(role: .inactive) }
}

/// The colors of one app color: every meaning's color, and the board. Multicolor gives each
/// meaning its own system color (Anki's for studying); the other app colors are tinted: the app
/// color for building, learned, correct and to do, the label colors for learning (secondary) and
/// new (primary), red for wrong (purple where the app color is red or pink). Design/COLORS.md
/// has the table.
nonisolated struct Theme {
    let appColor: AppColor

    /// The tinted themes' color: the app color (graphite's gray would read as learning: indigo).
    private var tint: Color { appColor == .graphite ? .indigo : appColor.tint }
    private var multicolor: Bool { appColor == .multicolor }

    func color(_ role: ThemeColor.Role) -> Color {
        switch role {
        case .built: tint
        case .learned, .correct: multicolor ? .green : tint
        case .learning: multicolor ? .red : .secondary
        case .new: multicolor ? .blue : .primary
        case .todo: multicolor ? .orange : tint
        case .wrong: [.red, .pink].contains(appColor) ? .purple : .red
        case .failure: .red
        case .ahead: .cyan
        case .inactive: multicolor ? .gray : Color.secondary.opacity(0.4)
        }
    }

    var board: BoardTheme { BoardTheme(theme: self) }
}

nonisolated extension EnvironmentValues {
    @Entry var theme = Theme(appColor: .default)
}

/// The app's color, chosen in Settings, the same on every device (Multicolor, blue controls with
/// Anki's colors for studying; then the Mac's accent colors, blue first, then indigo): buttons,
/// selection, progress and the board's tint. On the Mac it follows the system accent: when that
/// changes, the app color becomes it (`AppTint`).
nonisolated enum AppColor: String, CaseIterable, Identifiable {
    case multicolor, blue, indigo, purple, pink, red, orange, yellow, green, graphite

    static let key = "appColor"
    static let `default` = AppColor.multicolor

    var id: Self { self }
    var title: String { rawValue.capitalized }

    /// The tint to set: the app color itself (Multicolor is blue).
    var tint: Color {
        switch self {
        case .multicolor, .blue: .blue
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

    /// The board's tint: the app color itself.
    var board: Color { tint }

    #if os(macOS)
    /// The Mac's accent color (System Settings › Appearance) as an app color: its
    /// `AppleAccentColor` value (red 0, orange 1, yellow 2, green 3, blue 4, purple 5, pink 6,
    /// graphite -1), Multicolor when it has none.
    static var systemAccent: AppColor {
        guard let value = UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int else { return .multicolor }
        return [-1: .graphite, 0: .red, 1: .orange, 2: .yellow, 3: .green, 4: .blue, 5: .purple, 6: .pink][value] ?? .multicolor
    }
    #endif
}

extension View {
    /// Applies the app color from Settings: the accent and the theme.
    func appTint() -> some View { modifier(AppTint()) }
}

private struct AppTint: ViewModifier {
    @AppStorage(AppColor.key) private var appColor = AppColor.default
    /// The Mac accent last applied, so a color chosen in Settings stays until the accent changes.
    @AppStorage("appliedSystemAccent") private var appliedSystemAccent = ""

    func body(content: Content) -> some View {
        content
            .tint(appColor.tint)
            .environment(\.theme, Theme(appColor: appColor))
            #if os(macOS)
            .onAppear(perform: followSystemAccent)
            .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in
                followSystemAccent()
            }
            #endif
    }

    #if os(macOS)
    /// Takes the Mac's accent as the app color when it differs from the one last applied.
    private func followSystemAccent() {
        let accent = AppColor.systemAccent
        guard accent.rawValue != appliedSystemAccent else { return }
        appliedSystemAccent = accent.rawValue
        appColor = accent
    }
    #endif
}

/// The board for a theme: content with its own colors (not the app's light or dark
/// appearance), its squares tinted toward the app color, its overlays in the theme's colors.
nonisolated struct BoardTheme {
    let theme: Theme

    var light: Color { Color("BoardLight").mix(with: theme.appColor.board, by: 0.14) }
    var dark: Color { Color("BoardDark").mix(with: theme.appColor.board, by: 0.28) }
    /// The board's ink, tinted like the progress colors: the app color mixed halfway to black,
    /// which every board shows clearly (a board swallows its own hue). Your moves, the hint,
    /// the replies you cover and, dashed, the gaps; the ✓ badge in tinted themes.
    var ink: Color { theme.appColor.board.mix(with: .black, by: 0.55) }
    /// The ✓ badge: Multicolor's green for correct; tinted themes the ink (the app color itself
    /// would fade on its own board).
    var correct: Color { theme.appColor == .multicolor ? theme.color(.correct) : ink }
    var wrong: Color { theme.color(.wrong) }
    /// The last move and the selected square: the app color over the square (the ink for
    /// graphite, whose gray the board doesn't show).
    var lastMove: Color { theme.appColor == .graphite ? ink.opacity(0.25) : theme.appColor.board.opacity(0.5) }
    var selected: Color { theme.appColor == .graphite ? ink.opacity(0.4) : theme.appColor.board.opacity(0.75) }
    /// The engine's lines: quiet, there are often three of them.
    let engine = Color(.sRGB, red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255)
}
