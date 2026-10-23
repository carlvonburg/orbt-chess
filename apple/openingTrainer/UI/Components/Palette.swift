import SwiftUI

// The app's colors, by meaning (Design/COLORS.md). Each meaning has one hue in a theme, always
// next to a symbol, text or shape; views use these roles, never a hue by name. The accent (the
// app color, system indigo by default, or the Mac user's choice) is for controls only and never
// carries meaning.

/// A color by its meaning, resolved by the app's `Theme` where it is drawn: views say what a
/// color means (`.done`, `.attention`), the theme decides the hue, so a change of app color
/// reaches every view.
nonisolated struct ThemeColor: ShapeStyle, Hashable {
    enum Role: Hashable {
        /// Done: covered, your move, a correct answer, learned (Anki's review, young, mature).
        case done
        /// Something to do: missing coverage (gaps, the empty part of a coverage bar), a streak
        /// at risk, a leech.
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
        /// The board's last move and selected square.
        case highlight
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
    /// Something to do: gaps, the empty part of a coverage bar, a streak at risk, a leech.
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
        case .highlight: appColor == .yellow ? .indigo : .yellow
        }
    }

    var board: BoardTheme { BoardTheme(theme: self) }
}

nonisolated extension EnvironmentValues {
    @Entry var theme = Theme(appColor: .default)
}

/// The app's color, chosen in Settings (the Mac's accent colors, indigo first): buttons,
/// selection and the board's tint. It never carries meaning, so it may share a hue with a
/// meaning color.
nonisolated enum AppColor: String, CaseIterable, Identifiable {
    case indigo, blue, purple, pink, red, orange, yellow, green, graphite

    static let key = "appColor"
    /// Indigo, the app icon's color.
    static let `default` = AppColor.indigo

    var id: Self { self }
    var title: String { rawValue.capitalized }

    /// The tint to set; nil for indigo, the asset catalog's accent, which a Mac user's accent
    /// color replaces.
    var tint: Color? {
        switch self {
        case .indigo: nil
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

    /// The board's tint: the app color itself, not a Mac user's accent (a green or orange
    /// accent would tint the board like the arrows).
    var board: Color {
        switch self {
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

    func body(content: Content) -> some View {
        content
            .tint(appColor.tint)
            .environment(\.theme, Theme(appColor: appColor))
    }
}

/// The board for a theme: content with its own colors (not the app's light or dark
/// appearance), its squares tinted toward the app color, its overlays in the theme's colors.
nonisolated struct BoardTheme {
    let theme: Theme

    var light: Color { Color("BoardLight").mix(with: theme.appColor.board, by: 0.14) }
    var dark: Color { Color("BoardDark").mix(with: theme.appColor.board, by: 0.28) }
    /// Your moves, the hint and the replies you cover.
    var done: Color { theme.color(.done) }
    var gap: Color { theme.color(.attention) }
    var wrong: Color { theme.color(.wrong) }
    var lastMove: Color { theme.color(.highlight).opacity(0.42) }
    var selected: Color { theme.color(.highlight).opacity(0.68) }
    /// The engine's lines: quiet, there are often three of them.
    let engine = Color(.sRGB, red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255)
}
