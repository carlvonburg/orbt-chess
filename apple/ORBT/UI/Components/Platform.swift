import SwiftUI

// The same views on iPhone, iPad and macOS: the few iOS-only modifiers and toolbar
// placements, with what macOS uses instead.

extension View {
    /// Hides the tab bar on a pushed screen with its own actions (iPhone and iPad).
    func hidesTabBar() -> some View {
        #if os(iOS)
        toolbarVisibility(.hidden, for: .tabBar)
        #else
        self
        #endif
    }

    /// Capitalizes words while typing a name (iPhone and iPad).
    func wordsAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.words)
        #else
        self
        #endif
    }

    /// A button that is a whole form row: the row is the button on iPhone and iPad; macOS
    /// would draw a bordered button inside the row, so it's plain there.
    func formRowButton() -> some View {
        #if os(macOS)
        buttonStyle(.plain)
        #else
        self
        #endif
    }

    /// The outline a long-press lifts above the context menu (iPhone and iPad; a macOS context
    /// menu has no preview).
    func contextMenuPreviewShape(_ shape: some Shape) -> some View {
        #if os(iOS)
        contentShape(.contextMenuPreview, shape)
        #else
        self
        #endif
    }

    /// The scene's margin above content that starts right under the window toolbar (macOS;
    /// on iPhone and iPad the navigation bar already leaves room).
    func toolbarTopMargin() -> some View {
        #if os(macOS)
        scenePadding(.top)
        #else
        self
        #endif
    }
}

/// A regular-width window: iPad (not Slide Over or a narrow window) and every Mac window.
func isRegularWidth(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
    #if os(macOS)
    true
    #else
    sizeClass == .regular
    #endif
}

extension ToolbarItemPlacement {
    /// Top trailing on iPhone and iPad; the window toolbar's primary place on macOS.
    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    /// Top leading on iPhone and iPad; the window toolbar's navigation place on macOS.
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// The bottom bar on iPhone and iPad; the window toolbar on macOS.
    static var bottomActions: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .automatic
        #endif
    }
}

