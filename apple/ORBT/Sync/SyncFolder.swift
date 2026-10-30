import Foundation
import OpeningCoreRust

/// The repertoire folder as the sync sees it: the files it handles (`syncFileKind`) directly
/// in the folder, and which of them changed since they were last reported to the core. A file
/// iCloud has not downloaded (only its `.Name.pgn.icloud` placeholder is there) is neither
/// reported nor taken as deleted: it is downloaded first.
///
/// Thread-safe and blocking: call it off the main actor.
nonisolated final class SyncFolder: @unchecked Sendable {
    let url: URL

    /// What a file looked like when it was last reported.
    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int?
    }

    private let lock = NSLock()
    private var reported: [String: Stamp] = [:]

    init(url: URL) {
        self.url = url.standardizedFileURL
    }

    /// The name of a file directly in this folder that the sync handles, or nil.
    func name(of file: URL) -> String? {
        guard file.deletingLastPathComponent().standardizedFileURL.path == url.path else { return nil }
        let name = file.lastPathComponent
        return syncFileKind(name: name) == nil ? nil : name
    }

    /// Every file, for `setLocalFiles`, and the names still downloading from iCloud (start
    /// again once there are none, or files would be taken as deleted here).
    func allFiles() -> (files: [LocalFile], downloading: Set<String>) {
        let (stamps, downloading) = scan()
        var files: [LocalFile] = []
        var reported: [String: Stamp] = [:]
        for (name, stamp) in stamps {
            guard let data = try? FileAccess.read(url.appending(path: name)) else { continue }
            files.append(LocalFile(name: name, data: data))
            reported[name] = stamp
        }
        lock.withLock { self.reported = reported }
        return (files.sorted { $0.name < $1.name }, downloading)
    }

    /// The files written or deleted since they were last reported: data, or nil for deleted.
    func changes() -> [(name: String, data: Data?)] {
        let (stamps, downloading) = scan()
        let before = lock.withLock { reported }
        var result: [(name: String, data: Data?)] = []
        for (name, stamp) in stamps.sorted(by: { $0.key < $1.key }) where before[name] != stamp {
            if let change = read(name, stamp: stamp) { result.append(change) }
        }
        for name in before.keys.sorted() where stamps[name] == nil && !downloading.contains(name) {
            lock.withLock { _ = reported.removeValue(forKey: name) }
            result.append((name, nil))
        }
        return result
    }

    /// One file, as it is now (after the app wrote or deleted it).
    func change(_ name: String) -> (name: String, data: Data?)? {
        let file = url.appending(path: name)
        guard FileManager.default.fileExists(atPath: file.path) else {
            let known = lock.withLock { reported.removeValue(forKey: name) != nil }
            return known ? (name, nil) : nil
        }
        return read(name, stamp: Self.stamp(file))
    }

    /// The stamp is taken before the bytes: a write in between shows up at the next scan.
    private func read(_ name: String, stamp: Stamp) -> (name: String, data: Data?)? {
        guard let data = try? FileAccess.read(url.appending(path: name)) else { return nil }
        lock.withLock { reported[name] = stamp }
        return (name, data)
    }

    private func scan() -> (stamps: [String: Stamp], downloading: Set<String>) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        var stamps: [String: Stamp] = [:]
        var downloading = Set<String>()
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                if syncFileKind(name: real) != nil {
                    downloading.insert(real)
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url.appending(path: real))
                }
                continue
            }
            guard syncFileKind(name: name) != nil,
                  (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            stamps[name] = Self.stamp(item)
        }
        return (stamps, downloading.subtracting(stamps.keys))
    }

    private static func stamp(_ file: URL) -> Stamp {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Stamp(modified: values?.contentModificationDate, size: values?.fileSize)
    }
}
