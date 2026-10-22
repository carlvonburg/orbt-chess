import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var model = model
        if isRegularWidth(sizeClass) {
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
