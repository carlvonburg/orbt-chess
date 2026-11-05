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
        if library.entries.isEmpty && !(library.isLoaded || library.expectsRepertoires) {
            // The first launch, until the folder is listed: the window's own background, as the
            // launch screen, then onboarding or the library.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        } else if library.entries.isEmpty && library.isLoaded {
            // Nothing for the tabs or the sidebar to show yet: the ways to a first repertoire.
            OnboardingView()
        } else if isRegularWidth(sizeClass) {
            // The library, loading (`LibraryView`) while iCloud Drive lists a folder that had
            // repertoires; never the welcome screen in between.
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
