import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var model = model
        content
            // Repertoires another device made arrive while onboarding shows (a new install):
            // the library takes its place in a cross-fade, not a cut.
            .animation(.smooth, value: showsOnboarding)
            // Here, over onboarding and the library alike: it stays while the first repertoire
            // replaces onboarding under it, and closes onto the screen it opens.
            .sheet(item: $model.setup) { request in
                RepertoireSetupFlow(mode: request.mode) { entry in
                    // A new repertoire opens on Browse, to enter its first moves.
                    let build = if case .new = request.mode { true } else { false }
                    model.pendingShow = PendingShow(entryID: entry.id, build: build)
                }
                // The form size, as the app's other sheets. Not fitted to the content: a Form
                // scrolls and has no height of its own, so a fitted sheet collapses to its
                // toolbar on iPad.
                .presentationSizing(.form)
            }
    }

    /// No repertoire to show, and none expected while the folder is listed.
    private var showsOnboarding: Bool {
        let library = model.library
        return library.entries.isEmpty && (library.isLoaded || !library.expectsRepertoires)
    }

    @ViewBuilder
    private var content: some View {
        @Bindable var model = model
        if showsOnboarding {
            // Nothing for the tabs or the sidebar to show: the ways to a first repertoire, at
            // once (HIG, Launching). A first launch never waits for iCloud Drive: repertoires
            // already there (another device's) replace this screen as they arrive.
            OnboardingView()
        } else if isRegularWidth(sizeClass) {
            // Also while iCloud Drive lists a folder that had repertoires: the library as it was
            // left, its rows placeholders (`LibraryView`), never the welcome screen in between.
            // iPad and Mac: the library's sidebar, with statistics in each overview.
            LibraryView()
        } else {
            TabView(selection: $model.selectedTab) {
                Tab("Repertoires", systemImage: "book", value: AppTab.repertoires) {
                    LibraryView()
                }
                Tab("Statistics", systemImage: "chart.bar", value: AppTab.statistics) {
                    StatisticsView()
                }
            }
        }
    }
}
