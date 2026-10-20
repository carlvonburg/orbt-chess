import Foundation
import OpeningCoreRust
import Testing
@testable import openingTrainer

/// iCloud conflict merging and file presenters, over a temporary folder. Real conflict versions
/// can only come from iCloud, so versions are handed in as readers of other files.
@Suite struct ConflictMergeTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "StorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test func sidecarVersionsKeepTheLatestReviewOfEachCard() throws {
        let current = sidecar(modified: "2026-10-01T10:00:00.000Z", targetGames: 500,
                              cards: ["a": 100, "b": 300])
        let other = sidecar(modified: "2026-10-02T10:00:00.000Z", targetGames: 800,
                            cards: ["a": 200, "b": 250, "c": 50])
        let url = try file("Test.otrep.json", current)
        let versionURL = try file("version.json", other)

        let merged = try FileAccess.mergeFile(at: url, versions: [{ try Data(contentsOf: versionURL) }]) {
            mergeSidecarData(a: $0, b: $1)
        }

        #expect(merged)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let cards = json["studyCards"] as! [String: [String: Any]]
        #expect(cards.mapValues { $0["lastReviewTime"] as! Int } == ["a": 200, "b": 300, "c": 50])
        // Settings come from the later change.
        #expect(json["targetGames"] as? Int == 800)
    }

    @Test func revlogVersionsAreUnitedById() throws {
        let url = try file("Test.otlog.jsonl", revlog([1, 2, 4]))
        let versionURL = try file("version.jsonl", revlog([2, 3]))

        let merged = try FileAccess.mergeFile(at: url, versions: [{ try Data(contentsOf: versionURL) }]) {
            mergeRevlogData(a: $0, b: $1)
        }

        #expect(merged)
        #expect(decodeRevlog(data: try Data(contentsOf: url)).map(\.id) == [1, 2, 3, 4])
    }

    @Test func severalVersionsAreAllMerged() throws {
        let url = try file("Test.otlog.jsonl", revlog([1]))
        let a = try file("a.jsonl", revlog([2]))
        let b = try file("b.jsonl", revlog([3]))

        _ = try FileAccess.mergeFile(at: url, versions: [{ try Data(contentsOf: a) }, { try Data(contentsOf: b) }]) {
            mergeRevlogData(a: $0, b: $1)
        }

        #expect(decodeRevlog(data: try Data(contentsOf: url)).map(\.id) == [1, 2, 3])
    }

    @Test func anUnreadableVersionLeavesTheFileAlone() throws {
        let original = revlog([1])
        let url = try file("Test.otlog.jsonl", original)
        let readable = try file("a.jsonl", revlog([2]))
        let missing = folder.appending(path: "not-downloaded.jsonl")

        let merged = try FileAccess.mergeFile(at: url, versions: [{ try Data(contentsOf: readable) },
                                                                  { try Data(contentsOf: missing) }]) {
            mergeRevlogData(a: $0, b: $1)
        }

        // Nothing was written, so the caller keeps the versions for a later try.
        #expect(!merged)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func aFailedSaveIsReported() throws {
        var merged: [Data] = []
        #expect(throws: CocoaError.self) {
            try FileAccess.mergeVersions([{ Data("x".utf8) }], merge: { merged.append($0) }) {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        #expect(merged == [Data("x".utf8)])
    }

    @Test func anUnreadableSidecarVersionIsDropped() {
        let current = sidecar(modified: "2026-10-01T10:00:00.000Z", targetGames: 500, cards: ["a": 1])
        #expect(mergeSidecarData(a: current, b: Data("not json".utf8)) != nil)
        #expect(mergeSidecarData(a: Data("x".utf8), b: Data("y".utf8)) == nil)
    }

    // MARK: Fixtures

    private func sidecar(modified: String, targetGames: Int, cards: [String: Int]) -> Data {
        let base = newSidecar(id: "6F9619FF-8B86-D011-B42D-00C04FC964FF", color: .white, database: .masters,
                              targetGames: Int64(targetGames), minGames: 30, now: .of(.now))
        var json = try! JSONSerialization.jsonObject(with: base) as! [String: Any]
        json["settingsModified"] = modified
        json["studyCards"] = cards.mapValues { last -> [String: Any] in
            ["added": 1, "ctype": 2, "due": 10, "easeFactor": 2500, "id": last, "interval": 3, "lapses": 0,
             "lastReviewTime": last, "originalPosition": 0, "queue": 2, "remainingSteps": 0, "reps": 1]
        }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func revlog(_ ids: [Int64]) -> Data {
        Data(ids.map { id in
            #"{"cid":"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -","ease":3,"factor":224,"id":\#(id),"ivl":1,"lastIvl":0,"time":1000,"type":1}"#
                + "\n"
        }.joined().utf8)
    }
}

/// The presenter answers other processes' saves, deletions and moves.
@Suite struct FilePresenterTests {
    let url: URL

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PresenterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appending(path: "Test.pgn")
        try Data("1. e4 *".utf8).write(to: url)
    }

    @Test func aMoveUpdatesTheURL() async throws {
        let moved = Box<URL>()
        let presenter = FilePresenter(url: url, handlers: .init(changed: {}, moved: { moved.value = $0 }))
        presenter.start()
        defer { presenter.stop() }
        let destination = url.deletingLastPathComponent().appending(path: "Renamed.pgn")

        try await background { try FileAccess.move(url, to: destination) }

        try await until { moved.value != nil }
        #expect(moved.value?.lastPathComponent == "Renamed.pgn")
        #expect(presenter.presentedItemURL?.lastPathComponent == "Renamed.pgn")
    }

    @Test func aDeletionWaitsForTheHandler() async throws {
        let deleted = Box<Bool>()
        let presenter = FilePresenter(url: url, handlers: .init(changed: {}, deleted: { deleted.value = true }))
        presenter.start()
        defer { presenter.stop() }

        try await background { try FileAccess.delete(url) }

        #expect(deleted.value == true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func anotherReaderGetsPendingChangesSavedFirst() async throws {
        let presenter = FilePresenter(url: url, handlers: .init(changed: {}, save: { [url] in
            try? Data("1. d4 *".utf8).write(to: url)
        }))
        presenter.start()
        defer { presenter.stop() }

        let data = try await background { try FileAccess.read(url) }

        #expect(String(decoding: data, as: UTF8.self) == "1. d4 *")
    }

    /// Runs blocking coordinated IO off the main actor, where the presenter's handlers run.
    private func background<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached { try body() }.value
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }
}

private final class Box<T> {
    var value: T?
}
