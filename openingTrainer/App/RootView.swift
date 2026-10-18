import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Repertoires", systemImage: "book") {
                LibraryView()
            }
            Tab("Statistics", systemImage: "chart.bar") {
                StatisticsView()
            }
        }
    }
}
