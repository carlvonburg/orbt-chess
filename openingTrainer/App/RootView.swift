import OpeningCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("Repertoires", systemImage: "books.vertical") {
                LibraryView()
            }
            Tab("Train", systemImage: "graduationcap") {
                TrainHomeView()
            }
            .badge(dueCount)
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    private var dueCount: Int {
        model.library.entries.reduce(0) { total, entry in
            if let doc = model.documents[entry.id] {
                _ = doc.revision
                return total + doc.learningProgress().due
            }
            return total + (entry.sidecar?.cards.values.filter { $0.isDue(at: .now) }.count ?? 0)
        }
    }
}
