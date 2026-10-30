import Foundation
import OpeningCoreRust
import Testing
@testable import ORBT

/// One at a time: the sync and these tests share `FileAccessHooks`.
@Suite(.serialized) enum SyncTests {}

/// `SyncService` with the core's real `RepertoireSync` against a fake Dropbox (the requests the
/// core builds, answered by URL), over a temporary folder; as Android's `SyncServiceTest`.
extension SyncTests {
@MainActor
@Suite final class Service {
    let root: URL
    let folder: URL
    let server = FakeDropbox()
    let defaults: UserDefaults
    let suite = "SyncServiceTests-\(UUID().uuidString)"
    var documents: [RepertoireDocument] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "SyncTests-\(UUID().uuidString)")
        folder = root.appending(path: "Repertoires")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private struct App {
        let library: RepertoireLibrary
        let sync: SyncService
        let explorer: ExplorerService
    }

    private func app() async -> App {
        let library = RepertoireLibrary(folder: folder)
        await library.setUp()
        let sync = SyncService(library: library, documents: { [unowned self] in documents }, support: root,
                               defaults: defaults, secretPrefix: "test-\(suite)-") { [server] in server.handle($0) }
        return App(library: library, sync: sync, explorer: ExplorerService(store: ExplorerCacheStore(), auth: LichessAuth()))
    }

    private func signIn(_ app: App) {
        app.sync.connect(.dropbox, SyncCredentials(accessToken: FakeDropbox.token, refreshToken: FakeDropbox.refresh,
                                                   account: "me@example.com"))
    }

    private func open(_ entry: RepertoireEntry, in app: App) async throws -> RepertoireDocument {
        let loaded = try await RepertoireDocument.load(pgnURL: entry.pgnURL, sidecarURL: entry.sidecarURL,
                                                       defaults: TrainingDefaults.studyDefaults, explorer: app.explorer.core)
        let document = RepertoireDocument(entry: entry, loaded: loaded, explorer: app.explorer)
        documents.append(document)
        return document
    }

    private func sidecar() -> Data {
        newSidecar(id: "test", color: .white, database: .masters, targetGames: 100, now: .of(.now))
    }

    private func local(_ name: String) -> Data? { try? Data(contentsOf: folder.appending(path: name)) }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting until \(what)")
        throw CancellationError()
    }

    /// Until the sync has nothing left to do.
    private func settled(_ app: App) async throws {
        try await until("synced") { app.sync.state == .idle && app.sync.unsynced.isEmpty && !server.busy }
    }

    private func signOut(_ app: App) async {
        await app.sync.signOut()
        for document in documents { await document.close() }
    }

    @Test func firstSyncUploadsTheLocalFiles() async throws {
        let app = await app()
        _ = try app.library.create(name: "Italian", sidecar: sidecar())
        signIn(app)
        try await until("uploaded") { server.data("Italian.otrep.json") != nil && server.data("Italian.pgn") != nil }
        try await settled(app)
        #expect(app.sync.provider == .dropbox)
        #expect(app.sync.account == "me@example.com")
        #expect(server.data("Italian.pgn") == local("Italian.pgn"))
        #expect(server.data("Italian.otrep.json") == local("Italian.otrep.json"))
        // The state names what was uploaded (saved once the outcome naming it is applied).
        let stateFile = root.appending(path: "Sync-dropbox.json")
        try await until("the state is saved") {
            (try? String(contentsOf: stateFile, encoding: .utf8))?.contains("Italian.pgn") == true
        }
        let state = try String(contentsOf: root.appending(path: "Sync-dropbox.json"), encoding: .utf8)
        #expect(state.contains("Italian.pgn"))
        await signOut(app)
    }

    @Test func aRemoteChangeIsWrittenAndHandedToTheOpenDocument() async throws {
        let app = await app()
        let entry = try app.library.create(name: "Italian", sidecar: sidecar())
        signIn(app)
        try await until("uploaded") { server.data("Italian.pgn") != nil }
        try await settled(app)
        let document = try await open(entry, in: app)

        // Another device adds a move, and a repertoire.
        server.put("Italian.pgn", Data("[Event \"Italian\"]\n\n1. e4 e5 *\n".utf8))
        server.put("Najdorf.pgn", Data("[Event \"Najdorf\"]\n\n1. e4 c5 *\n".utf8))
        app.sync.syncNow()
        try await until("the move is in the document") { document.tree.child(of: RepertoireTree.rootID, uci: "e2e4") != nil }
        try await until("the new repertoire is in the folder") { local("Najdorf.pgn") != nil }
        try await settled(app)
        #expect(String(decoding: local("Italian.pgn") ?? Data(), as: UTF8.self).contains("e4 e5"))
        #expect(server.data("Najdorf.pgn") == local("Najdorf.pgn"))
        // The sync's own writes are not sent back.
        #expect(!server.uploadedNames.contains("Najdorf.pgn"))
        await signOut(app)
    }

    @Test func aLocalSaveIsUploaded() async throws {
        let app = await app()
        let entry = try app.library.create(name: "Italian", sidecar: sidecar())
        signIn(app)
        try await until("uploaded") { server.data("Italian.pgn") != nil }
        try await settled(app)
        let document = try await open(entry, in: app)

        document.addMove("d2d4", after: RepertoireTree.rootID)
        await document.flush()
        try await until("the save is uploaded") { server.data("Italian.pgn") == local("Italian.pgn") }
        try await settled(app)
        #expect(String(decoding: server.data("Italian.pgn") ?? Data(), as: UTF8.self).contains("d4"))
        await signOut(app)
    }

    @Test func aFileChangedByAnotherAppIsUploaded() async throws {
        let app = await app()
        _ = try app.library.create(name: "Italian", sidecar: sidecar())
        signIn(app)
        try await until("uploaded") { server.data("Italian.pgn") != nil }
        try await settled(app)

        // Written without FileAccess, as iCloud or the Files app would: found by the folder's scan.
        try Data("[Event \"Italian\"]\n\n1. e4 e5 2. Nf3 *\n".utf8).write(to: folder.appending(path: "Italian.pgn"))
        app.sync.resume()
        try await until("uploaded") { String(decoding: server.data("Italian.pgn") ?? Data(), as: UTF8.self).contains("Nf3") }
        await signOut(app)
    }

    @Test func editsMadeOfflineUploadWhenTheNetworkIsBack() async throws {
        let app = await app()
        let entry = try app.library.create(name: "Italian", sidecar: sidecar())
        signIn(app)
        try await until("uploaded") { server.data("Italian.pgn") != nil }
        try await settled(app)
        let document = try await open(entry, in: app)

        server.offline = true
        document.addMove("c2c4", after: RepertoireTree.rootID)
        await document.flush()
        try await until("offline") { if case .offline = app.sync.state { true } else { false } }
        #expect(app.sync.unsynced.contains("Italian.pgn"))

        server.offline = false
        app.sync.syncNow()
        try await until("uploaded") { String(decoding: server.data("Italian.pgn") ?? Data(), as: UTF8.self).contains("c4") }
        try await settled(app)
        await signOut(app)
    }

    @Test func aRevokedSignInAsksToSignInAgain() async throws {
        let app = await app()
        _ = try app.library.create(name: "Italian", sidecar: sidecar())
        signIn(app)
        try await until("uploaded") { server.data("Italian.pgn") != nil }
        try await settled(app)

        // The user removed the app in Dropbox: every token is refused.
        server.revoke()
        app.sync.syncNow()
        try await until("asked to sign in") { app.sync.needsSignIn }

        // Signing in again goes on syncing.
        server.restore()
        signIn(app)
        try await settled(app)
        #expect(!app.sync.needsSignIn)
        await signOut(app)
    }

    @Test func signingOutKeepsTheFiles() async throws {
        let app = await app()
        _ = try app.library.create(name: "Italian", sidecar: sidecar())
        signIn(app)
        try await until("uploaded") { server.data("Italian.pgn") != nil }
        try await settled(app)
        await app.sync.signOut()
        // Revoked on the server, not only forgotten here.
        #expect(server.revoked)
        #expect(app.sync.provider == nil)
        #expect(local("Italian.pgn") != nil)
        #expect(server.data("Italian.pgn") != nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Sync-dropbox.json").path))
    }
}

}

/// A fake Dropbox App folder answering the core's requests by URL (as the core's own test,
/// `orbt-core/tests/sync.rs`): revs counting up, conditional uploads and deletes.
nonisolated final class FakeDropbox: @unchecked Sendable {
    static let token = "access"
    static let refresh = "refresh"

    private struct Stored {
        let data: Data
        let rev: String
    }

    private let lock = NSLock()
    private var files: [String: Stored] = [:]
    private var uploads: [String] = []
    private var nextRev = 0
    private var access = FakeDropbox.token
    private var refreshToken = FakeDropbox.refresh
    private var _offline = false
    private var _revoked = false
    private var inFlight = 0

    var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }
    /// Signed out with `auth/token/revoke`.
    var revoked: Bool { lock.withLock { _revoked } }
    /// A request other than the long poll is being answered.
    var busy: Bool { lock.withLock { inFlight > 0 } }
    var uploadedNames: [String] { lock.withLock { uploads } }

    func data(_ name: String) -> Data? { lock.withLock { files[name]?.data } }

    @discardableResult
    func put(_ name: String, _ data: Data) -> String {
        lock.withLock { store(name, data) }
    }

    private func store(_ name: String, _ data: Data) -> String {
        nextRev += 1
        let rev = String(format: "%09x", nextRev)
        files[name] = Stored(data: data, rev: rev)
        return rev
    }

    func revoke() { lock.withLock { access = "revoked"; refreshToken = "revoked" } }
    func restore() { lock.withLock { access = Self.token; refreshToken = Self.refresh } }

    func handle(_ request: HttpRequest) -> HttpResponse? {
        lock.withLock {
            if _offline { return nil }
            return answer(request)
        }
    }

    private func answer(_ r: HttpRequest) -> HttpResponse {
        let endpoint = r.url.components(separatedBy: ".com").last ?? ""
        let body = String(decoding: r.body, as: UTF8.self)
        if endpoint == "/oauth2/token" {
            return body.contains("refresh_token=\(refreshToken)") && refreshToken != "revoked"
                ? Self.respond(200, #"{"access_token": "\#(access)", "expires_in": 14400, "token_type": "bearer"}"#)
                : Self.respond(400, #"{"error": "invalid_grant"}"#)
        }
        if endpoint == "/2/files/list_folder/longpoll" { return Self.respond(200, #"{"changes": false}"#) }
        if Self.header(r, "Authorization") != "Bearer \(access)" || access == "revoked" {
            return Self.respond(401, #"{"error_summary": "invalid_access_token/"}"#)
        }
        if endpoint == "/2/auth/token/revoke" {
            _revoked = true
            access = "revoked"
            refreshToken = "revoked"
            return Self.respond(200, "null")
        }
        let arg = Self.header(r, "Dropbox-API-Arg") ?? body
        let name = Self.field(arg, "path").map { String($0.drop { $0 == "/" }) }
        switch endpoint {
        case "/2/files/list_folder", "/2/files/list_folder/continue":
            let entries = files.keys.sorted().map { n in
                #"{".tag": "file", "name": "\#(n)", "rev": "\#(files[n]!.rev)", "id": "id:\#(n)"}"#
            }.joined(separator: ",")
            return Self.respond(200, #"{"entries": [\#(entries)], "cursor": "c\#(nextRev)", "has_more": false}"#)
        case "/2/files/download":
            guard let name, let file = files[name] else { return Self.conflict("path/not_found/") }
            return HttpResponse(status: 200, headers: [Header(name: "Dropbox-API-Result",
                                                              value: #"{"name": "\#(name)", "rev": "\#(file.rev)"}"#)],
                                body: file.data)
        case "/2/files/upload":
            guard let name else { return Self.conflict("path/malformed/") }
            let current = files[name]?.rev
            let ok = switch Self.field(arg, ".tag") {
            case "add": current == nil
            case "update": current != nil && current == Self.field(arg, "update")
            default: false
            }
            guard ok else { return Self.conflict("path/conflict/file/..") }
            uploads.append(name)
            let rev = store(name, r.body)
            return Self.respond(200, #"{"name": "\#(name)", "rev": "\#(rev)"}"#)
        case "/2/files/delete_v2":
            guard let name, let current = files[name] else { return Self.conflict("path_lookup/not_found/") }
            guard current.rev == Self.field(arg, "parent_rev") else { return Self.conflict("path_lookup/conflict/") }
            files[name] = nil
            return Self.respond(200, "{}")
        default:
            return Self.respond(400, "unexpected endpoint \(endpoint)")
        }
    }

    private static func header(_ r: HttpRequest, _ name: String) -> String? {
        r.headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// A string field of the request's JSON (the fake's names are plain ASCII).
    private static func field(_ json: String, _ name: String) -> String? {
        let pattern = "\"" + NSRegularExpression.escapedPattern(for: name) + "\":\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let range = Range(match.range(at: 1), in: json) else { return nil }
        return String(json[range])
    }

    private static func respond(_ status: UInt16, _ body: String) -> HttpResponse {
        HttpResponse(status: status, headers: [], body: Data(body.utf8))
    }

    private static func conflict(_ summary: String) -> HttpResponse {
        respond(409, #"{"error_summary": "\#(summary)", "error": {".tag": "path"}}"#)
    }
}

/// The folder as the sync sees it, and the folder chosen on the Mac.
extension SyncTests {
@Suite struct Folder {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "SyncFolderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: folder.appending(path: name))
    }

    @Test func onlyTheSyncsFilesAreReported() throws {
        try write("Italian.pgn", "1. e4 *")
        try write("Italian.otrep.json", "{}")
        try write("notes.txt", "x")
        try FileManager.default.createDirectory(at: folder.appending(path: "Coverage"), withIntermediateDirectories: true)
        let (files, downloading) = SyncFolder(url: folder).allFiles()
        #expect(files.map(\.name) == ["Italian.otrep.json", "Italian.pgn"])
        #expect(downloading.isEmpty)
    }

    @Test func changesAreFoundByDateAndSize() throws {
        try write("Italian.pgn", "1. e4 *")
        try write("Najdorf.pgn", "1. e4 c5 *")
        let sync = SyncFolder(url: folder)
        _ = sync.allFiles()
        #expect(sync.changes().isEmpty)

        try write("Italian.pgn", "1. e4 e5 *")
        try FileManager.default.removeItem(at: folder.appending(path: "Najdorf.pgn"))
        try write("Caro.pgn", "1. e4 c6 *")
        let changes = sync.changes()
        #expect(changes.map(\.name) == ["Caro.pgn", "Italian.pgn", "Najdorf.pgn"])
        #expect(changes.map(\.data) == [Data("1. e4 c6 *".utf8), Data("1. e4 e5 *".utf8), nil])
        // Reported once.
        #expect(sync.changes().isEmpty)
    }

    @Test func aFileStillInICloudIsNeitherReportedNorTakenAsDeleted() throws {
        try write("Italian.pgn", "1. e4 *")
        let sync = SyncFolder(url: folder)
        _ = sync.allFiles()
        // iCloud evicted it: only the placeholder is left.
        try FileManager.default.removeItem(at: folder.appending(path: "Italian.pgn"))
        try write(".Italian.pgn.icloud", "")
        #expect(sync.changes().isEmpty)
        #expect(SyncFolder(url: folder).allFiles().downloading == ["Italian.pgn"])
    }

    @Test func theAppsWritesAreToldWithTheFile() throws {
        let told = Told()
        FileAccessHooks.shared.observer = { [folder] url in
            if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { told.append(url.lastPathComponent) }
        }
        defer { FileAccessHooks.shared.observer = nil }
        let url = folder.appending(path: "Italian.pgn")
        try FileAccess.write(Data("1. e4 *".utf8), to: url)
        try FileAccess.append(Data(" ".utf8), to: url)
        try FileAccess.move(url, to: folder.appending(path: "Ruy.pgn"))
        try FileAccess.delete(folder.appending(path: "Ruy.pgn"))
        #expect(told.names == ["Italian.pgn", "Italian.pgn", "Italian.pgn", "Ruy.pgn", "Ruy.pgn"])
    }

    @Test func savesInTheChosenFolderKeepTheFile() throws {
        let url = folder.appending(path: "Italian.pgn")
        try FileAccess.write(Data("1. e4 *".utf8), to: url)
        let before = try inode(url)
        // Elsewhere: atomic, a new file.
        try FileAccess.write(Data("1. e4 e5 *".utf8), to: url)
        #expect(try inode(url) != before)

        FileAccessHooks.shared.chosenFolder = folder
        defer { FileAccessHooks.shared.chosenFolder = nil }
        let kept = try inode(url)
        try FileAccess.write(Data("1. d4 *".utf8), to: url)
        #expect(try inode(url) == kept)
        #expect(try Data(contentsOf: url) == Data("1. d4 *".utf8))
    }

    @Test func conflictCopiesInTheChosenFolderAreMergedThenDeleted() throws {
        try write("Italian.otlog.jsonl", revlogLine(1))
        try write("Italian (Carl's conflicted copy 2026-10-30).otlog.jsonl", revlogLine(2))
        let previous = ConflictCopies.pairs
        ConflictCopies.pairs = { names in
            names.compactMap { name in
                name.contains("conflicted copy") ? (name, "Italian.otlog.jsonl") : nil
            }
        }
        defer { ConflictCopies.pairs = previous }
        let url = folder.appending(path: "Italian.otlog.jsonl")

        // Not the chosen folder (iCloud Drive): names are the user's.
        try FileAccess.resolveConflicts(at: url) { mergeRevlogData(a: $0, b: $1) }
        #expect(decodeRevlog(data: try Data(contentsOf: url)).map(\.id) == [1])

        FileAccessHooks.shared.chosenFolder = folder
        defer { FileAccessHooks.shared.chosenFolder = nil }
        try FileAccess.resolveConflicts(at: url) { mergeRevlogData(a: $0, b: $1) }
        #expect(decodeRevlog(data: try Data(contentsOf: url)).map(\.id) == [1, 2])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Italian.otlog.jsonl"])
    }

    private func inode(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    private func revlogLine(_ id: Int64) -> String {
        #"{"cid":"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -","ease":3,"factor":224,"id":\#(id),"ivl":1,"lastIvl":0,"time":1000,"type":1}"#
            + "\n"
    }
}

}

nonisolated private final class Told: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    var names: [String] { lock.withLock { _names } }
    func append(_ name: String) { lock.withLock { _names.append(name) } }
}
