import SwiftUI

@main
struct OpeningTrainerApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.library.setUp() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.flushAll() }
            if phase == .active { model.library.refresh() }
        }
    }
}
