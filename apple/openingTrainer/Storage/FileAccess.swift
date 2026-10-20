import Foundation

/// Coordinated reads and writes, so iCloud and other apps see consistent files.
nonisolated enum FileAccess {
    static func read(_ url: URL) throws -> Data {
        var coordError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { actual in
            result = Result { try Data(contentsOf: actual) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    static func write(_ data: Data, to url: URL, presenter: NSFilePresenter? = nil) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { actual in
            do { try data.write(to: actual, options: .atomic) } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    /// Appends to a file, creating it if needed.
    static func append(_ data: Data, to url: URL) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { actual in
            do {
                if let handle = try? FileHandle(forWritingTo: actual) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: actual, options: .atomic)
                }
            } catch {
                writeError = error
            }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    static func delete(_ url: URL) throws {
        var coordError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { actual in
            do { try FileManager.default.removeItem(at: actual) } catch { deleteError = error }
        }
        if let coordError { throw coordError }
        if let deleteError { throw deleteError }
    }

    static func move(_ url: URL, to destination: URL) throws {
        var coordError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forMoving,
                               writingItemAt: destination, options: .forReplacing, error: &coordError) { from, to in
            do {
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if let coordError { throw coordError }
        if let moveError { throw moveError }
    }

    /// Merges iCloud conflict versions into the current file with `merge`, then resolves them.
    static func resolveConflicts(at url: URL, merge: (Data) -> Void) {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty else { return }
        for version in conflicts {
            if let data = try? Data(contentsOf: version.url) { merge(data) }
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
}

/// Forwards file-change callbacks to the main actor.
nonisolated final class FilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let onChange: @MainActor @Sendable () -> Void

    init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        presentedItemURL = url
        self.onChange = onChange
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }

    func start() { NSFileCoordinator.addFilePresenter(self) }
    func stop() { NSFileCoordinator.removeFilePresenter(self) }

    nonisolated func presentedItemDidChange() {
        let onChange = onChange
        Task { @MainActor in onChange() }
    }

    nonisolated func presentedSubitemDidChange(at url: URL) {
        presentedItemDidChange()
    }

    nonisolated func presentedItemDidGain(_ version: NSFileVersion) {
        presentedItemDidChange()
    }
}
