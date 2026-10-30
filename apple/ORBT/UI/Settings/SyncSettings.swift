import OpeningCoreRust
import SwiftUI
import UniformTypeIdentifiers

/// Sync: the repertoire folder synced with Dropbox or Google Drive as well as iCloud Drive, chosen and
/// confirmed here, with its status, Sync Now, and signing in again when the provider asks. On
/// the Mac a folder inside Dropbox or Google Drive for desktop can be chosen instead
/// (`FolderSection`); the provider's own app syncs it, so there is no sign-in then.
struct SyncSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var confirming: SyncProvider?
    @State private var confirmingStop = false

    var body: some View {
        let sync = model.sync
        if !model.library.usesChosenFolder, !SyncProvider.available.isEmpty || sync.provider != nil {
            Section {
                if let provider = sync.provider {
                    LabeledContent("Syncing with", value: sync.account.map { "\(provider.title) (\($0))" } ?? provider.title)
                    SyncStatusRow(sync: sync)
                    if sync.needsSignIn {
                        Button("Sign In Again", systemImage: "person.crop.circle.badge.exclamationmark") {
                            Task { await sync.signIn(provider, using: webAuth) }
                        }
                        .disabled(sync.isSigningIn)
                    } else {
                        Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { sync.syncNow() }
                    }
                    Button("Stop Syncing", role: .destructive) { confirmingStop = true }
                        .confirmationDialog("Stop Syncing?", isPresented: $confirmingStop, titleVisibility: .visible) {
                            Button("Stop Syncing", role: .destructive) { Task { await sync.signOut() } }
                        } message: {
                            Text("Your repertoires stay on this device and in iCloud Drive, and in \(provider.title) as they are now. Changes are no longer synced there.")
                        }
                } else {
                    ForEach(SyncProvider.available) { provider in
                        Button("Sync with \(provider.title)…") { confirming = provider }
                            .disabled(sync.isSigningIn)
                            .confirmationDialog("Sync with \(provider.title)?", isPresented: Binding(
                                get: { confirming == provider }, set: { if !$0 { confirming = nil } }
                            ), titleVisibility: .visible) {
                                Button("Sign In") { Task { await sync.signIn(provider, using: webAuth) } }
                            } message: {
                                Text("Your repertoires are uploaded to the ORBT Chess folder in \(provider.title), and merged with those already there. Nothing is deleted.")
                            }
                    }
                    if sync.isSigningIn { SyncStatusRow(sync: sync) }
                }
                if let error = sync.lastError {
                    Text(error).font(.footnote).foregroundStyle(.failure)
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Also keeps your repertoires and training progress in the ORBT Chess folder of \(providers), for your devices without iCloud. ORBT Chess sees only that folder.")
            }
        }
    }
}

extension SyncSection {
    /// "Dropbox or Google Drive", or the one in use.
    private var providers: String {
        if let provider = model.sync.provider { return provider.title }
        return SyncProvider.available.map(\.title).formatted(.list(type: .or))
    }
}

/// The core's state in words; anything that asks the user to act is colored.
private struct SyncStatusRow: View {
    let sync: SyncService

    var body: some View {
        let status = status
        LabeledContent("Status") {
            Label(status.text, systemImage: status.symbol)
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

#if os(macOS)
/// The Mac's repertoire folder: iCloud Drive's, or one chosen inside Dropbox or Google Drive
/// for desktop (whose app syncs it; a security-scoped bookmark keeps it across launches).
struct FolderSection: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false
    @State private var error: String?

    var body: some View {
        let library = model.library
        Section {
            LabeledContent("Folder") {
                Text(library.usesChosenFolder ? library.folder?.path(percentEncoded: false) ?? ""
                     : library.usesICloud ? "iCloud Drive › ORBT Chess" : "On this Mac")
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Button("Choose Folder…") { choosing = true }
            if library.usesChosenFolder {
                Button("Use iCloud Drive") { use(nil) }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.failure) }
        } header: {
            Text("Repertoire folder")
        } footer: {
            Text("To sync with Dropbox or Google Drive, choose a folder inside it: their app keeps it up to date on your other computers. Repertoires already in the folder are opened; those in the current folder are not moved.")
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): use(url)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private func use(_ url: URL?) {
        error = nil
        Task {
            // The panel's URL is in scope until the bookmark is made and opened again.
            let accessing = url?.startAccessingSecurityScopedResource() ?? false
            defer { if accessing { url?.stopAccessingSecurityScopedResource() } }
            do {
                try await model.useFolder(url)
            } catch {
                self.error = "Could not use this folder: \(error.localizedDescription)"
            }
        }
    }
}
#endif
