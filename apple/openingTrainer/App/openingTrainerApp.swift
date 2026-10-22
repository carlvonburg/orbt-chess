import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct OpeningTrainerApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Settings-style forms on every platform: iOS's default, and on the Mac what
                // System Settings uses (the Mac's default is a column layout).
                .formStyle(.grouped)
                .task {
                    #if os(macOS)
                    appDelegate.model = model
                    #endif
                    await model.library.setUp()
                    await model.setUpCoverageTables()
                }
        }
        // The first window's size; macOS restores the size people give it after that.
        .defaultSize(width: 1400, height: 900)
        .commands { BuilderCommands() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushInBackground() }
            if phase == .active {
                Task {
                    await model.library.refresh()
                    await model.reloadCoverageTables()
                }
            }
        }
        #if os(macOS)
        // Opening Trainer > Settings… (⌘,), as on every Mac app.
        Settings {
            SettingsView()
                .environment(model)
                .formStyle(.grouped)
                .frame(width: 480, height: 600)
        }
        #endif
    }

    /// Saves pending changes when the app leaves the foreground. On iOS a background task
    /// keeps the app running until the files are written.
    private func flushInBackground() {
        #if os(iOS)
        let task = BackgroundTask(name: "Save repertoires")
        Task {
            await model.flushAll()
            task.end()
        }
        #else
        Task { await model.flushAll() }
        #endif
    }
}

#if os(iOS)
/// A UIKit background task, ended once (when the work is done or time runs out).
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif

#if os(macOS)
/// Writes pending changes before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.flushAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
