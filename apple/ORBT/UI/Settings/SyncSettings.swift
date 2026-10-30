import OpeningCoreRust
import SwiftUI

/// Sync: where the repertoires are kept in step across devices, one of iCloud Drive, Dropbox,
/// Google Drive or none (this device only), confirmed before it changes: moving to Dropbox or
/// Google Drive (or off) takes them out of iCloud Drive onto the device, moving back puts them
/// in iCloud Drive again. With a provider: its status, Sync Now, and signing in again.
struct SyncSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var pending: SyncChoice?
    @State private var working = false

    var body: some View {
        let sync = model.sync
        Section {
            Picker("Sync with", selection: Binding(get: { current }, set: { if $0 != current { pending = $0 } })) {
                ForEach(choices) { Text($0.title).tag($0) }
            }
            .disabled(working || sync.isSigningIn)
            .confirmationDialog(pending.map { "Sync with \($0.title)?" } ?? "", isPresented: Binding(
                get: { pending != nil }, set: { if !$0 { pending = nil } }
            ), titleVisibility: .visible, presenting: pending) { choice in
                Button(choice.isProvider ? "Sign In" : "Change") { change(to: choice) }
            } message: { choice in
                Text(message(for: choice))
            }
            if let provider = sync.provider {
                if let account = sync.account { LabeledContent("Account", value: account) }
                SyncStatusRow(sync: sync)
                if sync.needsSignIn {
                    Button("Sign In Again", systemImage: "person.crop.circle.badge.exclamationmark") {
                        Task { await sync.signIn(provider, using: webAuth) }
                    }
                    .disabled(sync.isSigningIn)
                } else {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { sync.syncNow() }
                }
            } else if sync.isSigningIn || working {
                SyncStatusRow(sync: sync)
            }
            if let error = sync.lastError ?? model.library.lastError {
                Text(error).font(.footnote).foregroundStyle(.failure)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Keeps your repertoires and training progress the same on your other devices: iCloud Drive for your Apple devices, Dropbox or Google Drive for all of them. ORBT Chess sees only its own folder there.")
        }
    }

    private var current: SyncChoice {
        if let provider = model.sync.provider { return .provider(provider) }
        return model.library.usesICloud ? .iCloud : .off
    }

    /// iCloud Drive while there is an iCloud account (or it is in use), the providers this build
    /// has, and off.
    private var choices: [SyncChoice] {
        var choices: [SyncChoice] = []
        if FileManager.default.ubiquityIdentityToken != nil || model.library.usesICloud { choices.append(.iCloud) }
        choices += SyncProvider.available.map(SyncChoice.provider)
        if let provider = model.sync.provider, !SyncProvider.available.contains(provider) { choices.append(.provider(provider)) }
        choices.append(.off)
        return choices
    }

    private func message(for choice: SyncChoice) -> String {
        let from = current
        switch choice {
        case .provider(let provider):
            let leaving = from == .iCloud
                ? " They move from iCloud Drive to this device; iCloud Drive keeps its copies as they are now."
                : ""
            let stopping = if case .provider(let old) = from { " \(old.title) stops syncing them and keeps its copies." } else { "" }
            return "Your repertoires are uploaded to the ORBT Chess folder in \(provider.title) and merged with those already there.\(leaving)\(stopping) Nothing is deleted."
        case .iCloud:
            let stopping = if case .provider(let old) = from { " \(old.title) stops syncing them and keeps its copies." } else { "" }
            return "Your repertoires move to iCloud Drive and are merged with those already there.\(stopping) Nothing is deleted."
        case .off:
            let stopping = if case .provider(let old) = from { "\(old.title) stops syncing them and keeps its copies." }
                else { "They move from iCloud Drive to this device; iCloud Drive keeps its copies as they are now." }
            return "Your repertoires are kept on this device only. \(stopping)"
        }
    }

    private func change(to choice: SyncChoice) {
        let sync = model.sync
        working = true
        Task {
            defer { working = false }
            switch choice {
            case .provider(let provider):
                // One provider at a time: the old one signs out (its files stay there) first.
                if sync.provider != nil { await sync.signOut() }
                await sync.signIn(provider, using: webAuth)
            case .iCloud:
                if sync.provider != nil { await sync.signOut(toICloud: true) } else { await model.moveRepertoires(toICloud: true) }
            case .off:
                if sync.provider != nil { await sync.signOut() } else { await model.moveRepertoires(toICloud: false) }
            }
        }
    }
}

/// What syncs the repertoires: iCloud Drive, a provider, or nothing.
enum SyncChoice: Hashable, Identifiable {
    case iCloud
    case provider(SyncProvider)
    case off

    var id: String {
        switch self {
        case .iCloud: "icloud"
        case .provider(let provider): provider.rawValue
        case .off: "off"
        }
    }

    var title: String {
        switch self {
        case .iCloud: "iCloud Drive"
        case .provider(let provider): provider.title
        case .off: "Off (This Device Only)"
        }
    }

    var isProvider: Bool { if case .provider = self { true } else { false } }
}

/// The core's state in words; anything that asks the user to act is colored.
private struct SyncStatusRow: View {
    let sync: SyncService

    var body: some View {
        let status = status
        // A symbol and text, not a `Label`: on iOS a Label as a form row's content took several
        // rows' height below the text.
        LabeledContent("Status") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: status.symbol)
                Text(status.text)
            }
            .foregroundStyle(status.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        }
    }

    /// The provider refused the sign-in (revoked, unused for months, or expired): nothing
    /// syncs until the user signs in again; edits made meanwhile upload then.
    private var signedOut: String {
        "\(sync.provider?.title ?? "The provider") signed ORBT Chess out. Sign in again to keep syncing; your changes are kept."
    }

    private var status: (text: String, symbol: String, color: ThemeColor?) {
        let pending = switch sync.unsynced.count {
        case 0: ""
        case 1: " 1 file not uploaded yet."
        case let n: " \(n) files not uploaded yet."
        }
        func time(_ ms: Int64) -> String {
            Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(date: .omitted, time: .shortened)
        }
        if sync.isSigningIn { return ("Signing in…", "arrow.triangle.2.circlepath", nil) }
        if sync.needsSignIn { return (signedOut + pending, "exclamationmark.icloud", .todo) }
        if sync.waitingForDownloads > 0 {
            return ("Waiting for iCloud Drive to download \(sync.waitingForDownloads == 1 ? "1 file" : "\(sync.waitingForDownloads) files").",
                    "icloud.and.arrow.down", nil)
        }
        return switch sync.state {
        case .syncing: ("Syncing…\(pending)", "arrow.triangle.2.circlepath", nil)
        case .needsToken: ("Signing in…", "arrow.triangle.2.circlepath", nil)
        case .needsSignIn: (signedOut + pending, "exclamationmark.icloud", .todo)
        case .offline(let until): ("Offline. Trying again at \(time(until)).\(pending)", "icloud.slash", nil)
        case .paused(let until): ("Waiting for the provider until \(time(until)).\(pending)", "icloud.slash", nil)
        case .idle: sync.unsynced.isEmpty
            ? ("Up to date", "checkmark.icloud", nil)
            : ("Waiting to upload.\(pending)", "icloud.and.arrow.up", nil)
        }
    }
}

