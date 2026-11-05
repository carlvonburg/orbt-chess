import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var model = model
        content
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

    @ViewBuilder
    private var content: some View {
        @Bindable var model = model
        let library = model.library
        if library.entries.isEmpty && (library.isLoaded || library.remembered.isEmpty) {
            // Nothing for the tabs or the sidebar to show: the ways to a first repertoire, at
            // once (HIG, Launching). A first launch never waits for iCloud Drive: its repertoires
            // replace this screen as they arrive, and it says while it looks for them.
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
