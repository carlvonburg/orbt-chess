import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
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
