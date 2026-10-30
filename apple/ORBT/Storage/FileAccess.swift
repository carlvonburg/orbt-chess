import Foundation

/// Coordinated reads and writes, so iCloud and other apps see consistent files. Blocking:
/// call from a background task, never the main actor.
nonisolated enum FileAccess {
    static func read(_ url: URL, presenter: NSFilePresenter? = nil) throws -> Data {
        var coordError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [], error: &coordError) { actual in
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
        FileAccessHooks.shared.changed(url)
    }

    /// Appends to a file, creating it if needed.
    static func append(_ data: Data, to url: URL, presenter: NSFilePresenter? = nil) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { actual in
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
        FileAccessHooks.shared.changed(url)
    }

    static func delete(_ url: URL) throws {
        var coordError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { actual in
            do { try FileManager.default.removeItem(at: actual) } catch { deleteError = error }
        }
        if let coordError { throw coordError }
        if let deleteError { throw deleteError }
        FileAccessHooks.shared.changed(url)
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
        FileAccessHooks.shared.changed(url)
        FileAccessHooks.shared.changed(destination)
    }

    // MARK: iCloud conflicts

    /// Merges iCloud conflict versions of `url` and resolves them. `merge` takes each version's
    /// bytes; `save` then writes the merged result. The versions are removed only once every one
    /// was merged and the result is saved, so a failure never loses a version.
    static func resolveConflicts(at url: URL, presenter: NSFilePresenter? = nil,
                                 merge: (Data) throws -> Void, save: () throws -> Void) throws {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return }
        let merged = try mergeVersions(versions.map { version in { try Data(contentsOf: version.url) } },
                                       merge: merge, save: save)
        guard merged else { return }
        for version in versions { version.isResolved = true }
        try removeOtherVersions(of: url, presenter: presenter)
    }

    /// Conflict versions of a file whose bytes merge on their own (the sidecar, the review log):
    /// the file and each version are combined with `merge`, and the result replaces the file.
    static func resolveConflicts(at url: URL, presenter: NSFilePresenter? = nil,
                                 merge: (Data, Data) -> Data?) throws {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return }
        let merged = try mergeFile(at: url, versions: versions.map { version in { try Data(contentsOf: version.url) } },
                                   presenter: presenter, merge: merge)
        guard merged else { return }
        for version in versions { version.isResolved = true }
        try removeOtherVersions(of: url, presenter: presenter)
    }

    /// Combines the file with each version and writes the result; see `mergeVersions`.
    static func mergeFile(at url: URL, versions: [() throws -> Data], presenter: NSFilePresenter? = nil,
                          merge: (Data, Data) -> Data?) throws -> Bool {
        var current = try read(url, presenter: presenter)
        return try mergeVersions(versions) { version in
            if let result = merge(current, version) { current = result }
        } save: {
            try write(current, to: url, presenter: presenter)
        }
    }

    /// Feeds each version to `merge`, then calls `save`. False, with nothing saved, when a
    /// version could not be read (not downloaded yet): it is merged on a later try.
    static func mergeVersions(_ versions: [() throws -> Data], merge: (Data) throws -> Void,
                              save: () throws -> Void) throws -> Bool {
        var contents: [Data] = []
        for read in versions {
            guard let data = try? read() else { return false }
            contents.append(data)
        }
        for data in contents { try merge(data) }
        try save()
        return true
    }

    private static func removeOtherVersions(of url: URL, presenter: NSFilePresenter?) throws {
        var coordError: NSError?
        var removeError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { actual in
            do { try NSFileVersion.removeOtherVersionsOfItem(at: actual) } catch { removeError = error }
        }
        if let coordError { throw coordError }
        if let removeError { throw removeError }
    }
}

/// What the app's own file changes tell (the sync, which uploads them).
/// Thread-safe: `FileAccess` calls it from any thread.
nonisolated final class FileAccessHooks: @unchecked Sendable {
    static let shared = FileAccessHooks()

    private let lock = NSLock()
    private var _observer: (@Sendable (URL) -> Void)?

    /// Told after each write, append, delete or move (both ends), on the thread that made it.
    var observer: (@Sendable (URL) -> Void)? {
        get { lock.withLock { _observer } }
        set { lock.withLock { _observer = newValue } }
    }

    func changed(_ url: URL) { observer?(url) }
}

/// Watches a file or folder and forwards its callbacks to the main actor.
nonisolated final class FilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    struct Handlers {
        /// The item or one inside it changed, or a new version (a conflict) arrived.
        var changed: @MainActor @Sendable () -> Void
        /// Another process is about to read: write what is pending.
        var save: (@MainActor @Sendable () async -> Void)?
        /// The item is about to be deleted: stop using it without writing it again.
        var deleted: (@MainActor @Sendable () async -> Void)?
        /// The item was moved or renamed by someone else.
        var moved: (@MainActor @Sendable (URL) -> Void)?
    }

    let presentedItemOperationQueue = OperationQueue()
    private let lock = NSLock()
    private var url: URL
    private let handlers: Handlers

    init(url: URL, handlers: Handlers) {
        self.url = url
        self.handlers = handlers
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }

    convenience init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.init(url: url, handlers: Handlers(changed: onChange))
    }

    var presentedItemURL: URL? { lock.withLock { url } }

    func start() { NSFileCoordinator.addFilePresenter(self) }
    func stop() { NSFileCoordinator.removeFilePresenter(self) }

    func presentedItemDidChange() {
        let changed = handlers.changed
        Task { @MainActor in changed() }
    }

    func presentedSubitemDidChange(at url: URL) {
        presentedItemDidChange()
    }

    func presentedItemDidGain(_ version: NSFileVersion) {
        presentedItemDidChange()
    }

    func savePresentedItemChanges(completionHandler: @escaping @Sendable (Error?) -> Void) {
        guard let save = handlers.save else { return completionHandler(nil) }
        Task { @MainActor in
            await save()
            completionHandler(nil)
        }
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
        guard let deleted = handlers.deleted else { return completionHandler(nil) }
        Task { @MainActor in
            await deleted()
            completionHandler(nil)
        }
    }

    func presentedItemDidMove(to newURL: URL) {
        lock.withLock { url = newURL }
        guard let moved = handlers.moved else { return }
        Task { @MainActor in moved(newURL) }
    }
}
