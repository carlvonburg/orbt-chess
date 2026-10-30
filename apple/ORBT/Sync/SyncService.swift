import Foundation
import Observation
import OpeningCoreRust
import AuthenticationServices
import SwiftUI
import os

/// Runs the core's sync of the repertoire folder with Dropbox (`orbt_core::sync`): sends the
/// requests it hands out (one at a time, plus Dropbox's long poll while the app is in front),
/// reports the answers and applies the outcomes to the files. What to download, upload, merge
/// or delete is the core's; this does the IO, the timers and the sign-in. The folder is the
/// library's (iCloud Drive's "ORBT Chess" or Documents), so iCloud keeps syncing it too.
///
/// The local files: every file at start (`setLocalFiles`), then every change: the app's own
/// writes through `FileAccess` (`FileAccessHooks.observer`), and what the folder's presenter
/// reports (iCloud, the Files app), found by comparing each file's date and size. The sync's
/// own writes are reported too; they hold the bytes the core already has, so they change
/// nothing there. An open repertoire's files go through its document (`applyRemote`,
/// `removedRemotely`), which merges them into what is on screen.
@Observable
final class SyncService {
    /// Nil: repertoires sync with iCloud Drive only.
    private(set) var provider: SyncProvider?
    private(set) var account: String?
    private(set) var state: SyncState = .idle
    /// Files whose local version is not uploaded yet.
    private(set) var unsynced: [String] = []
    /// Files iCloud is still downloading; syncing starts once they are here.
    private(set) var waitingForDownloads = 0
    var lastError: String?
    private(set) var isSigningIn = false

    var needsSignIn: Bool { state == .needsSignIn }

    @ObservationIgnored private let library: RepertoireLibrary
    @ObservationIgnored private let documents: () -> [RepertoireDocument]
    @ObservationIgnored private let send: @Sendable (HttpRequest) async -> HttpResponse?
    @ObservationIgnored private let support: URL
    @ObservationIgnored private var core: RepertoireSync?
    @ObservationIgnored private var folder: SyncFolder?
    @ObservationIgnored private var presenter: FilePresenter?
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private var scheduledScan: Task<Void, Never>?
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// One outcome at a time: its files written before the state that names them is saved.
    @ObservationIgnored private var applying: Task<Void, Never>?
    @ObservationIgnored private var foreground = true
    /// Where the core is reached from `FileAccess`'s threads.
    @ObservationIgnored private let hook = Hook()

    nonisolated private static let log = Logger(subsystem: "org.orbtchess.orbt", category: "sync")
    static let providerKey = "syncProvider"
    private static let maxSignOutRequests = 3

    init(library: RepertoireLibrary, documents: @escaping () -> [RepertoireDocument],
         support: URL = .applicationSupportDirectory,
         send: @escaping @Sendable (HttpRequest) async -> HttpResponse? = { await HTTP.send($0) }) {
        self.library = library
        self.documents = documents
        self.support = support
        self.send = send
    }

    nonisolated static func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    /// After the library is set up: the provider chosen in Settings, if this build has it.
    /// Nothing runs while the library has no folder or uses a folder chosen on the Mac (the
    /// provider's own app syncs that one).
    func start() {
        guard core == nil, starting == nil, library.folder != nil, !library.usesChosenFolder,
              let chosen = UserDefaults.standard.string(forKey: Self.providerKey).flatMap(SyncProvider.init),
              SyncProvider.available.contains(chosen) else { return }
        let stored = storedCredentials(chosen)
        account = stored?.account
        provider = chosen
        begin(chosen, stored)
    }

    /// Stops syncing without signing out (the library's folder changes): `start` resumes it.
    func suspend() {
        stop()
        state = .idle
    }

    /// Back in front: look for changes from other devices, long-poll (Dropbox).
    func resume() {
        foreground = true
        guard let core else { return }
        core.setWatching(watching: true)
        core.syncNow()
        scheduleScan(after: .zero)
    }

    /// In the background: no long poll.
    func background() {
        foreground = false
        core?.setWatching(watching: false)
    }

    /// "Sync Now": retries what failed.
    func syncNow() {
        lastError = nil
        core?.resume()
        core?.syncNow()
    }

    /// Signs in to `provider` and syncs with it from now on. The local files are kept and
    /// merged with the provider's: nothing is deleted. False when the user cancelled or the
    /// sign-in failed (`lastError`).
    @discardableResult
    func signIn(_ provider: SyncProvider, using session: WebAuthenticationSession) async -> Bool {
        lastError = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            guard let credentials = try await SyncAuth.signIn(provider, using: session) else { return false }
            let previous = storedCredentials(provider)?.account
            stop()
            // Another account (or one we can't tell): what was synced says nothing about its
            // files, so start over (both sides are merged once).
            if credentials.account == nil || credentials.account != previous || self.provider != provider {
                try? FileManager.default.removeItem(at: stateFile(provider))
            }
            storeCredentials(provider, credentials)
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            self.provider = provider
            account = credentials.account
            if library.folder != nil, !library.usesChosenFolder { begin(provider, credentials) }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Stops syncing: the files stay on this device, the provider's stay there. The sign-in is
    /// revoked on the provider's side (the core's requests; best effort, offline leaves it).
    func signOut() async {
        guard let provider else { return }
        let sync = core ?? makeCore(provider, credentials: storedCredentials(provider))
        stop()
        await revoke(sync)
        Keychain.delete(secretKey(provider))
        UserDefaults.standard.removeObject(forKey: Self.providerKey)
        try? FileManager.default.removeItem(at: stateFile(provider))
        self.provider = nil
        account = nil
        lastError = nil
        unsynced = []
        waitingForDownloads = 0
        state = .idle
    }

    // MARK: Starting and stopping

    private func makeCore(_ provider: SyncProvider, credentials: SyncCredentials?) -> RepertoireSync {
        let saved = (try? Data(contentsOf: stateFile(provider))) ?? Data()
        let sync = switch provider {
        case .dropbox: RepertoireSync.dropbox(appKey: SyncAuth.clientID(for: .dropbox), savedState: saved)
        }
        if let credentials {
            sync.setCredentials(accessToken: credentials.accessToken, expiresAt: credentials.expiresAt,
                                refreshToken: credentials.refreshToken)
        }
        return sync
    }

    /// Reads the folder (waiting for iCloud's downloads), then hands it to the core and syncs.
    private func begin(_ provider: SyncProvider, _ credentials: SyncCredentials?) {
        guard let url = library.folder else { return }
        let sync = makeCore(provider, credentials: credentials)
        let folder = SyncFolder(url: url)
        starting = Task { [weak self] in
            defer { self?.starting = nil }
            while !Task.isCancelled {
                let (files, downloading) = await Task.detached(priority: .utility) { folder.allFiles() }.value
                guard let self, !Task.isCancelled else { return }
                self.waitingForDownloads = downloading.count
                guard downloading.isEmpty else {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                self.run(sync, folder: folder, files: files)
                return
            }
        }
    }

    private func run(_ sync: RepertoireSync, folder: SyncFolder, files: [LocalFile]) {
        core = sync
        self.folder = folder
        hook.set(sync, folder)
        sync.setListener(listener: Listener(service: self))
        FileAccessHooks.shared.observer = { [hook] url in hook.changed(url) }
        let presenter = FilePresenter(url: folder.url) { [weak self] in self?.scheduleScan(after: .seconds(1)) }
        presenter.start()
        self.presenter = presenter
        sync.setLocalFiles(files: files)
        sync.setWatching(watching: foreground)
        sync.syncNow()
    }

    private func stop() {
        starting?.cancel()
        starting = nil
        guard core != nil else { return }
        core = nil
        folder = nil
        hook.set(nil, nil)
        FileAccessHooks.shared.observer = nil
        presenter?.stop()
        presenter = nil
        wake?.cancel()
        wake = nil
        scheduledScan?.cancel()
        scheduledScan = nil
    }

    /// Sends the core's sign-out requests until there are none (at most a refresh and a revoke).
    private func revoke(_ sync: RepertoireSync) async {
        for _ in 0..<Self.maxSignOutRequests {
            guard let request = sync.signOutRequest(nowMs: Self.millis(.now)) else { return }
            let response = await send(request)
            sync.onSignOutResponse(response: response, nowMs: Self.millis(.now))
            if response == nil { return }
        }
    }

    // MARK: Local changes

    /// Reports the files whose date or size changed (iCloud, the Files app, anything the
    /// app's own hook missed).
    private func scheduleScan(after delay: Duration) {
        guard let folder, let sync = core else { return }
        scheduledScan?.cancel()
        scheduledScan = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let changes = await Task.detached(priority: .utility) { folder.changes() }.value
            guard let self, self.core === sync else { return }
            for change in changes { sync.localChanged(name: change.name, data: change.data) }
        }
    }

    // MARK: The core's queue

    /// Sends what the core hands out and sleeps until it wants to be asked again.
    fileprivate func pump() {
        guard let sync = core else { return }
        let poll = sync.poll(nowMs: Self.millis(.now))
        refresh(sync)
        for op in poll.ops {
            Task { await perform(sync, op) }
        }
        wake?.cancel()
        wake = poll.wakeAt.map { wakeAt in
            Task { [weak self] in
                let delay = wakeAt - Self.millis(.now)
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard !Task.isCancelled else { return }
                self?.pump()
            }
        }
    }

    private func perform(_ sync: RepertoireSync, _ op: SyncOp) async {
        let response = await send(op.request)
        if op.kind != .watch {
            Self.log.info("sync \(String(describing: op.kind)) \(op.file ?? "") \(response.map { String($0.status) } ?? "offline")")
        }
        // Signed out or switched meanwhile.
        guard core === sync else { return }
        let outcome = sync.onResponse(op: op, response: response, nowMs: Self.millis(.now))
        await apply(sync, outcome)
    }

    private func apply(_ sync: RepertoireSync, _ outcome: SyncOutcome) async {
        let previous = applying
        let task = Task { [weak self] in
            await previous?.value
            await self?.applyNow(sync, outcome)
        }
        applying = task
        await task.value
    }

    private func applyNow(_ sync: RepertoireSync, _ outcome: SyncOutcome) async {
        guard core === sync, let provider, let folder else { return }
        if !outcome.writes.isEmpty || !outcome.deletes.isEmpty {
            await applyFiles(outcome.writes, outcome.deletes, in: folder.url)
            await library.refresh()
        }
        // After the files: a state naming versions not written yet would upload the old ones.
        if outcome.saveState {
            let data = sync.savedState(), url = stateFile(provider)
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }.value
        }
        refresh(sync)
    }

    /// Writes and deletes the local files; an open repertoire's through its document.
    private func applyFiles(_ writes: [LocalWrite], _ deletes: [String], in folder: URL) async {
        var remote: [ObjectIdentifier: (document: RepertoireDocument, pgn: Data?, sidecar: Data?, revlog: Data?)] = [:]
        var plain: [LocalWrite] = []
        for write in writes where syncFileKind(name: write.name) != nil {
            guard let document = document(of: write.name) else {
                plain.append(write)
                continue
            }
            var entry = remote[ObjectIdentifier(document)] ?? (document, nil, nil, nil)
            switch write.name {
            case document.pgnURL.lastPathComponent: entry.pgn = write.data
            case document.sidecarURL.lastPathComponent: entry.sidecar = write.data
            default: entry.revlog = write.data
            }
            remote[ObjectIdentifier(document)] = entry
        }
        await Task.detached(priority: .utility) {
            for write in plain {
                do {
                    try FileAccess.write(write.data, to: folder.appending(path: write.name))
                } catch {
                    Self.log.error("sync could not write \(write.name): \(error.localizedDescription)")
                }
            }
        }.value
        for entry in remote.values {
            await entry.document.applyRemote(pgn: entry.pgn, sidecar: entry.sidecar, revlog: entry.revlog)
        }
        for name in deletes where syncFileKind(name: name) != nil {
            if let document = document(of: name), document.pgnURL.lastPathComponent == name {
                document.removedRemotely()
            }
            await Task.detached(priority: .utility) {
                let url = folder.appending(path: name)
                if FileManager.default.fileExists(atPath: url.path) { try? FileAccess.delete(url) }
            }.value
        }
    }

    private func document(of name: String) -> RepertoireDocument? {
        documents().first {
            $0.pgnURL.lastPathComponent == name || $0.sidecarURL.lastPathComponent == name
                || $0.revlogURL.lastPathComponent == name
        }
    }

    private func refresh(_ sync: RepertoireSync) {
        guard core === sync else { return }
        let state = sync.state()
        if state != self.state { self.state = state }
        let unsynced = sync.unsyncedFiles()
        if unsynced != self.unsynced { self.unsynced = unsynced }
    }

    // MARK: Stored sign-in

    private func stateFile(_ provider: SyncProvider) -> URL {
        support.appending(path: "Sync-\(provider.rawValue).json")
    }

    private func secretKey(_ provider: SyncProvider) -> String { "sync-\(provider.rawValue)" }

    /// The refresh token and the account (the access token is not kept: the core refreshes).
    private func storedCredentials(_ provider: SyncProvider) -> SyncCredentials? {
        guard let text = Keychain.read(secretKey(provider)) else { return nil }
        return try? JSONDecoder().decode(SyncCredentials.self, from: Data(text.utf8))
    }

    private func storeCredentials(_ provider: SyncProvider, _ credentials: SyncCredentials) {
        let kept = SyncCredentials(refreshToken: credentials.refreshToken, account: credentials.account)
        if let data = try? JSONEncoder().encode(kept), let text = String(data: data, encoding: .utf8) {
            Keychain.write(text, for: secretKey(provider))
        }
    }

    /// The core and the folder, for `FileAccess`'s observer on any thread: the app's own write
    /// is read back and reported there (the core object locks).
    private nonisolated final class Hook: @unchecked Sendable {
        private let lock = NSLock()
        private var sync: RepertoireSync?
        private var folder: SyncFolder?

        func set(_ sync: RepertoireSync?, _ folder: SyncFolder?) {
            lock.withLock { self.sync = sync; self.folder = folder }
        }

        func changed(_ url: URL) {
            let current: (RepertoireSync?, SyncFolder?) = lock.withLock { (sync, folder) }
            guard let sync = current.0, let folder = current.1, let name = folder.name(of: url), let change = folder.change(name) else { return }
            sync.localChanged(name: change.name, data: change.data)
        }
    }

    /// The core asks to be polled from any thread; hop to the main actor so it is not re-entered.
    private nonisolated final class Listener: SyncListener, @unchecked Sendable {
        weak var service: SyncService?
        init(service: SyncService) { self.service = service }
        func wake() {
            Task { @MainActor [weak self] in self?.service?.pump() }
        }
    }
}
