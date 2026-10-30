import Foundation
import Observation
import OpeningCoreRust

/// An open repertoire. The Rust core (`RepertoireDoc`) holds the tree, the sidecar and the
/// coverage and decides what each change means; this does the file IO it asks for: every edit
/// is written back to the PGN shortly after it happens, and changes made on another device are
/// handed to the core to merge.
@Observable
final class RepertoireDocument {
    private(set) var entryID: String
    private(set) var pgnURL: URL { didSet { files.update { $0.pgn = pgnURL } } }
    private(set) var sidecarURL: URL { didSet { files.update { $0.sidecar = sidecarURL } } }
    private(set) var name: String

    let core: RepertoireDoc
    /// Bumped on every change so views can refresh derived values.
    private(set) var revision: UInt64 = 0
    private(set) var saveError: String?
    private(set) var canUndo = false
    /// The window's undo stack, kept in step with the core's: one step per edit, so Edit >
    /// Undo, ⌘Z and the undo gesture undo the core's edits (see `attachUndo`).
    @ObservationIgnored private weak var undoManager: UndoManager?
    /// What an undo step runs: the builder's undo while one is open (it also leaves a
    /// position the undo removes), else the document's.
    @ObservationIgnored private var undoAction: (() -> Void)?
    @ObservationIgnored private var undoDepth = 0

    @ObservationIgnored let explorer: ExplorerService
    /// Told when the PGN was deleted, or moved out of the folder, by someone else.
    @ObservationIgnored var onRemoved: (() -> Void)?
    /// Told, with the old entry id, when someone else renamed the PGN.
    @ObservationIgnored var onRenamed: ((String) -> Void)?
    /// Runs the file IO off the main actor, one operation at a time, so saves land in order.
    @ObservationIgnored private let writer = Writer()
    @ObservationIgnored private var pgnSaveTask: Task<Void, Never>?
    @ObservationIgnored private var sidecarSaveTask: Task<Void, Never>?
    /// Where the files are, read by the writer when each operation runs.
    @ObservationIgnored private let files: FileState
    @ObservationIgnored private var presenters: Presenters? { didSet { files.update { $0.presenters = presenters } } }
    /// Closing: no new saves are scheduled and changes on disk are ignored.
    @ObservationIgnored private var isClosed = false
    /// The files are being deleted: nothing is written any more.
    @ObservationIgnored private var isDiscarded = false
    @ObservationIgnored private var cachedCards: (revision: UInt64, cards: [EPD: Card])?

    /// The opened core and what it asked for while opening and merging conflict versions.
    struct Loaded: Sendable {
        let document: RepertoireDoc
        let changes: [Changes]
    }

    /// Reads and parses the files off the main actor (a large PGN takes a moment to download and
    /// parse). iCloud conflict versions of the sidecar and the review log are merged into the
    /// files first; those of the PGN are merged into the document and the result is saved.
    nonisolated static func load(pgnURL: URL, sidecarURL: URL, defaults: StudyDefaults,
                                 explorer: Explorer) async throws -> Loaded {
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: pgnURL)
            try? resolveSidecarConflicts(at: sidecarURL)
            try? resolveRevlogConflicts(at: RepertoireLibrary.revlogURL(for: pgnURL))
            let sidecar = try FileAccess.read(sidecarURL)
            let text = String(decoding: try FileAccess.read(pgnURL), as: UTF8.self)
            let opened = try openRepertoire(pgnText: text, sidecar: sidecar, defaults: defaults, explorer: explorer)
            var changes = [opened.changes]
            try? resolvePGNConflicts(opened.document, at: pgnURL) { changes.append($0) }
            return Loaded(document: opened.document, changes: changes)
        }.value
    }

    /// `loaded` comes from `load`.
    init(entry: RepertoireEntry, loaded: Loaded, explorer: ExplorerService) {
        self.entryID = entry.id
        self.pgnURL = entry.pgnURL
        self.sidecarURL = entry.sidecarURL
        self.name = entry.name
        self.explorer = explorer
        files = FileState(Files(pgn: entry.pgnURL, sidecar: entry.sidecarURL))
        core = loaded.document
        core.setListener(listener: Listener(document: self))
        for changes in loaded.changes { apply(changes) }
        startPresenters()
    }

    /// Applies what the core changed: refreshes views and schedules the saves it asks for.
    func apply(_ changes: Changes) {
        if changes.revision != revision { revision = changes.revision }
        canUndo = core.canUndo()
        syncUndo()
        if let ms = changes.savePgnAfterMs { schedulePGNSave(after: ms) }
        if let ms = changes.saveSidecarAfterMs { scheduleSidecarSave(after: ms) }
        cachedCards = nil
    }

    /// The presenters of the three files. Each coordinated access passes its own file's
    /// presenter, so the app is not told about its own reads and writes.
    private nonisolated struct Presenters: Sendable {
        let pgn: FilePresenter
        let sidecar: FilePresenter
        let revlog: FilePresenter
        var all: [FilePresenter] { [pgn, sidecar, revlog] }
    }

    private func startPresenters() {
        let save: @MainActor @Sendable () async -> Void = { [weak self] in await self?.savePending() }
        let pgn = FilePresenter(url: pgnURL, handlers: .init(
            changed: { [weak self] in self?.pgnChangedOnDisk() },
            save: save,
            deleted: { [weak self] in self?.removedByOthers() },
            moved: { [weak self] in self?.pgnMoved(to: $0) }))
        let sidecar = FilePresenter(url: sidecarURL, handlers: .init(
            changed: { [weak self] in self?.sidecarChangedOnDisk() },
            save: save,
            moved: { [weak self] in self?.sidecarURL = $0 }))
        let revlog = FilePresenter(url: revlogURL, handlers: .init(
            changed: { [weak self] in self?.revlogChangedOnDisk() },
            save: save))
        presenters = Presenters(pgn: pgn, sidecar: sidecar, revlog: revlog)
        for p in [pgn, sidecar, revlog] { p.start() }
    }

    private func stopPresenters() {
        for p in presenters?.all ?? [] { p.stop() }
        presenters = nil
    }

    /// Renames the PGN, sidecar and review log. The entry id changes with the file names.
    func rename(to newName: String, in library: RepertoireLibrary) async throws {
        await flush()
        stopPresenters()
        defer { startPresenters() }
        let files = files
        let renamed = try await writer.run {
            let renamed = try RepertoireLibrary.renameFiles(pgn: files.current.pgn, to: newName)
            // Saves queued behind the rename go to the new files.
            files.update { $0.pgn = renamed.pgnURL; $0.sidecar = renamed.sidecarURL }
            return renamed
        }
        entryID = renamed.sidecarURL.path
        pgnURL = renamed.pgnURL
        sidecarURL = renamed.sidecarURL
        name = renamed.pgnURL.deletingPathExtension().lastPathComponent
        await library.refresh()
    }

    /// Saves what is pending and stops watching the files.
    func close() async {
        isClosed = true
        await flush()
        stopPresenters()
    }

    /// Stops without saving, for a repertoire whose files are being deleted: a save would
    /// recreate them.
    func discard() {
        isClosed = true
        isDiscarded = true
        files.update { $0.discarded = true }
        pgnSaveTask?.cancel()
        pgnSaveTask = nil
        sidecarSaveTask?.cancel()
        sidecarSaveTask = nil
        stopPresenters()
    }

    var color: Side { _ = revision; return core.color() }
    var database: ExplorerDatabase { _ = revision; return core.database() }
    var loadWarnings: [String] { core.loadWarnings() }

    /// The move tree, read from the core.
    var tree: Tree { Tree(core: core, revision: revision) }
    /// Coverage values, read from the core.
    var coverage: Coverage { Coverage(core: core, revision: revision) }
    /// Settings and cards, read from the core.
    var sidecar: SidecarValues { SidecarValues(document: self) }

    /// The cards, copied once per change.
    var studyCards: [EPD: Card] {
        if let cachedCards, cachedCards.revision == revision { return cachedCards.cards }
        let cards = core.cards()
        cachedCards = (revision, cards)
        return cards
    }

    // MARK: Stats

    func stats(_ epd: EPD) -> ExplorerStats? {
        // The core's cache isn't observed; reading `revision`, which stats arriving bump,
        // redraws views as soon as the stats come in.
        _ = revision
        return core.stats(epd: epd)
    }

    /// The opening name of a node, or of its nearest ancestor, from stats already loaded.
    func openingName(at id: NodeID) -> String? {
        _ = revision
        return core.openingName(id: id)
    }

    /// Fetches stats for the position on screen, ahead of the coverage check.
    func requestStats(for epd: EPD) {
        core.requestStats(epd: epd, nowMs: ExplorerService.millis(.now))
    }

    /// The coverage check runs while one of this repertoire's screens is showing (overview,
    /// builder, study), so the library and the other tabs never fetch. It only asks for
    /// opponent-to-move positions you would meet at least once in N games, most frequent first.
    func startCoverageCheck() { apply(core.startCoverageCheck()) }
    func stopCoverageCheck() { core.stopCoverageCheck() }

    /// Opponent positions above your target whose stats are not loaded yet.
    var uncheckedPositions: Int { _ = revision; return Int(core.uncheckedPositions()) }

    // MARK: Edits

    @discardableResult
    func addMove(_ uci: String, after parent: NodeID) -> NodeID? {
        let result = core.addMove(uci: uci, parent: parent)
        apply(result.changes)
        return result.node
    }

    /// Adds moves one after another; returns the last node.
    @discardableResult
    func addLine(_ ucis: [String], after start: NodeID) -> NodeID? {
        let result = core.addLine(ucis: ucis, start: start)
        apply(result.changes)
        return result.node
    }

    func delete(_ id: NodeID) { apply(core.delete(id: id)) }
    func promote(_ id: NodeID) { apply(core.promote(id: id)) }
    func setNote(_ text: String, for id: NodeID) { apply(core.setNote(text: text, id: id)) }
    func undo() { apply(core.undo()) }

    /// Mirrors the core's undo stack in the window's, with `action` as what undoing runs.
    func attachUndo(_ manager: UndoManager?, action: @escaping () -> Void) {
        undoManager?.removeAllActions(withTarget: self)
        undoManager = manager
        undoAction = action
        undoDepth = 0
        syncUndo()
    }

    /// One step per edit the core can undo. Undoing through the window's stack pops its step
    /// itself; the core's stack shrinking otherwise (the builder's Undo, or cleared by a
    /// remote change) rebuilds the steps. The core has no redo, so none is registered.
    private func syncUndo() {
        let depth = Int(core.undoDepth())
        defer { undoDepth = depth }
        guard let undoManager, !undoManager.isUndoing, depth != undoDepth else { return }
        if depth < undoDepth {
            undoManager.removeAllActions(withTarget: self)
            undoDepth = 0
        }
        for _ in undoDepth..<depth {
            undoManager.registerUndo(withTarget: self) { document in
                (document.undoAction ?? document.undo)()
            }
        }
    }

    // MARK: Settings and training

    func updateSettings(color: Side, database: ExplorerDatabase, targetGames: Int) {
        apply(core.updateSettings(color: color, database: database, targetGames: Int64(targetGames),
                                  now: .of(.now)))
    }

    /// Excludes an opponent move at `node`'s position from coverage, or includes it again.
    /// Applies wherever the position occurs.
    func setExcluded(_ uci: String, at node: NodeID, _ excluded: Bool) {
        apply(core.setExcluded(uci: uci, node: node, excluded: excluded, now: .of(.now)))
    }

    func isExcluded(_ uci: String, at node: NodeID) -> Bool {
        _ = revision
        return core.isExcluded(uci: uci, node: node)
    }

    func rememberLine(_ ucis: [String]) { apply(core.rememberLine(ucis: ucis)) }

    var revlogURL: URL { RepertoireLibrary.revlogURL(for: pgnURL) }

    func learningProgress(under node: NodeID = RepertoireTree.rootID) -> Progress {
        _ = revision
        return core.learningProgress(node: node)
    }

    /// Every move in the PGN, both sides.
    var savedMoveCount: Int { _ = revision; return Int(core.savedMoveCount()) }

    var practiceMode: PracticeMode { _ = revision; return core.practiceMode() }

    func remainingLimits(_ timing: SchedTiming) -> RemainingLimits { core.remainingLimits(timing: timing) }

    /// Today's New / Learning / To Review counts, as on Anki's deck overview.
    func studyCounts(timing: SchedTiming = SchedTiming()) -> Counts {
        _ = revision
        return core.studyCounts(timing: timing)
    }

    /// Anki's custom study "Increase today's new card limit".
    func extendNewLimitToday(by count: Int, timing: SchedTiming = SchedTiming()) {
        apply(core.extendLimitsToday(new: Int64(count), review: 0, timing: timing))
    }

    /// Anki's custom study "Increase today's review card limit".
    func extendReviewLimitToday(by count: Int, timing: SchedTiming = SchedTiming()) {
        apply(core.extendLimitsToday(new: 0, review: Int64(count), timing: timing))
    }

    /// Reviews due today beyond today's review limit.
    func reviewsBeyondLimit(timing: SchedTiming = SchedTiming()) -> Int {
        _ = revision
        return Int(core.reviewsBeyondLimit(timing: timing))
    }

    /// Daily limits ("This deck") and practice mode for this repertoire.
    func updateStudySettings(limits: DeckLimits, practiceMode: PracticeMode?) {
        apply(core.updateStudySettings(limits: limits, practiceMode: practiceMode, now: .of(.now)))
    }

    /// Your-turn positions under `node` where cards are asked.
    func cardEPDs(under node: NodeID = RepertoireTree.rootID) -> Set<EPD> {
        _ = revision
        return Set(core.cardEpds(root: node))
    }

    func cardNodes(under node: NodeID = RepertoireTree.rootID) -> [NodeID] {
        _ = revision
        return core.cardNodes(root: node)
    }

    func suspendedCardEPDs(under node: NodeID = RepertoireTree.rootID) -> Set<EPD> {
        _ = revision
        return Set(core.suspendedCardEpds(root: node))
    }

    func openingBranches() -> [NodeID] { core.openingBranches() }

    /// How often each node is reached.
    var reach: [NodeID: Double] { _ = revision; return core.reach() }

    /// The whole review log, including answers not written yet. Read off the main actor.
    func reviewLog() async -> [RevlogEntry] {
        let core = core
        return await readRevlog { core.reviewLog(onDisk: $0) }
    }

    /// This repertoire's part of the statistics; see `RepertoireDoc.graphParts`.
    func graphParts(wholeCollection: Bool) async -> GraphParts {
        let core = core
        return await readRevlog { core.graphParts(onDisk: $0, wholeCollection: wholeCollection) }
    }

    private func readRevlog<T: Sendable>(_ body: @escaping @Sendable (Data) -> T) async -> T {
        let files = files.current
        return await Task.detached(priority: .userInitiated) {
            body((try? FileAccess.read(files.revlog, presenter: files.presenters?.revlog)) ?? Data())
        }.value
    }

    // MARK: Saving

    /// Writes pending changes now (on close, when the app goes to background or quits, or when
    /// another process wants to read the files). Saves already running finish first: the
    /// writer runs one at a time, and these find nothing left when they had it all.
    func flush() async {
        pgnSaveTask?.cancel()
        pgnSaveTask = nil
        sidecarSaveTask?.cancel()
        sidecarSaveTask = nil
        await savePGN()
        await saveSidecar()
    }

    /// Another process wants to read the files: writes only what is waiting to be saved. The
    /// library reads every sidecar when it rescans, so a full flush here would serialize the
    /// whole PGN on each scan.
    private func savePending() async {
        if pgnSaveTask != nil || sidecarSaveTask != nil || core.revlogToAppend() != nil { await flush() }
    }

    func dismissSaveError() { saveError = nil }

    private func schedulePGNSave(after ms: UInt32) {
        guard !isClosed else { return }
        pgnSaveTask?.cancel()
        pgnSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(ms)))
            guard !Task.isCancelled, let self else { return }
            self.pgnSaveTask = nil
            await self.savePGN()
        }
    }

    private func scheduleSidecarSave(after ms: UInt32) {
        guard !isClosed else { return }
        sidecarSaveTask?.cancel()
        sidecarSaveTask = Task { [weak self] in
            if ms > 0 { try? await Task.sleep(for: .milliseconds(Int(ms))) }
            guard !Task.isCancelled, let self else { return }
            self.sidecarSaveTask = nil
            await self.saveSidecar()
        }
    }

    private func savePGN() async {
        guard !isDiscarded else { return }
        let core = core, files = files
        do {
            try await writer.run {
                let current = files.current
                guard !current.discarded else { return }
                try Self.savePGN(core, to: current.pgn, presenter: current.presenters?.pgn)
            }
            saveError = nil
        } catch {
            saveError = "Could not save \(pgnURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    nonisolated private static func savePGN(_ core: RepertoireDoc, to url: URL, presenter: FilePresenter?) throws {
        guard let text = core.pgnToSave() else { return }
        try FileAccess.write(Data(text.utf8), to: url, presenter: presenter)
        core.pgnSaved(text: text)
    }

    /// Appends new answers to the review log, then writes the sidecar.
    private func saveSidecar() async {
        guard !isDiscarded else { return }
        let core = core, files = files
        do {
            try await writer.run {
                let current = files.current
                guard !current.discarded else { return }
                if let lines = core.revlogToAppend() {
                    do {
                        try FileAccess.append(lines, to: current.revlog, presenter: current.presenters?.revlog)
                    } catch {
                        throw SaveError(message: "Could not save the review log: \(error.localizedDescription)")
                    }
                    core.revlogAppended()
                }
                guard let data = core.sidecarToSave(timing: SchedTiming()) else { return }
                try FileAccess.write(data, to: current.sidecar, presenter: current.presenters?.sidecar)
                core.sidecarSaved(data: data)
            }
        } catch let error as SaveError {
            saveError = error.message
        } catch {
            saveError = "Could not save training data: \(error.localizedDescription)"
        }
    }

    private struct SaveError: Error {
        let message: String
    }

    // MARK: Changes from elsewhere

    /// Reads and merges on the writer, so it never overlaps one of our own saves.
    private func pgnChangedOnDisk() {
        guard !isClosed else { return }
        let core = core, files = files
        Task {
            let changes = await writer.run { () -> [Changes] in
                let current = files.current
                var changes: [Changes] = []
                if let data = try? FileAccess.read(current.pgn, presenter: current.presenters?.pgn) {
                    changes.append(core.remotePgn(text: String(decoding: data, as: UTF8.self)))
                }
                try? Self.resolvePGNConflicts(core, at: current.pgn, presenter: current.presenters?.pgn) { changes.append($0) }
                return changes
            }
            for c in changes { apply(c) }
        }
    }

    private func sidecarChangedOnDisk() {
        guard !isClosed else { return }
        let core = core, files = files
        Task {
            let changes = await writer.run { () -> Changes? in
                let current = files.current
                try? Self.resolveSidecarConflicts(at: current.sidecar, presenter: current.presenters?.sidecar)
                guard let data = try? FileAccess.read(current.sidecar, presenter: current.presenters?.sidecar) else { return nil }
                return core.remoteSidecar(data: data)
            }
            // The core asks for a save only when the merge kept cards or settings the file lacks.
            if let changes { apply(changes) }
        }
    }

    private func revlogChangedOnDisk() {
        guard !isClosed else { return }
        let files = files
        Task {
            await writer.run {
                let current = files.current
                try? Self.resolveRevlogConflicts(at: current.revlog, presenter: current.presenters?.revlog)
            }
        }
    }

    /// Versions from the sync (another device's, or merged with it), written on the writer so
    /// they never overlap a save, and merged into the document as an iCloud change is. The
    /// review log is united with the file's, which may hold answers the sync has not seen.
    func applyRemote(pgn: Data?, sidecar: Data?, revlog: Data?) async {
        guard !isClosed else { return }
        let core = core, files = files
        let changes = await writer.run { () -> [Changes] in
            let current = files.current
            guard !current.discarded else { return [] }
            var changes: [Changes] = []
            if let pgn {
                try? FileAccess.write(pgn, to: current.pgn, presenter: current.presenters?.pgn)
                changes.append(core.remotePgn(text: String(decoding: pgn, as: UTF8.self)))
            }
            if let sidecar {
                try? FileAccess.write(sidecar, to: current.sidecar, presenter: current.presenters?.sidecar)
                changes.append(core.remoteSidecar(data: sidecar))
            }
            if let revlog {
                let local = try? FileAccess.read(current.revlog, presenter: current.presenters?.revlog)
                let merged = local.map { mergeRevlogData(a: $0, b: revlog) } ?? revlog
                try? FileAccess.write(merged, to: current.revlog, presenter: current.presenters?.revlog)
            }
            return changes
        }
        for c in changes { apply(c) }
    }

    /// The sync deleted the PGN (deleted on another device): the repertoire is gone from here.
    /// The sync is deleting the repertoire: closed and discarded, and back once no save of it
    /// is still running, so none writes a file again after it is deleted.
    func removedRemotely() async {
        removedByOthers()
        await writer.run {}
    }

    /// Someone else renamed or moved the PGN. Within the folder, the sidecar and the review log
    /// follow it (the library pairs them by name); out of it, the repertoire is gone from here.
    private func pgnMoved(to url: URL) {
        guard !isClosed, url.standardizedFileURL != pgnURL.standardizedFileURL else { return }
        guard url.deletingLastPathComponent().standardizedFileURL == pgnURL.deletingLastPathComponent().standardizedFileURL else {
            return removedByOthers()
        }
        let oldID = entryID, oldPGN = pgnURL
        let newSidecar = RepertoireLibrary.sidecarURL(for: url)
        pgnURL = url
        sidecarURL = newSidecar
        name = url.deletingPathExtension().lastPathComponent
        entryID = newSidecar.path
        Task {
            await writer.run { RepertoireLibrary.moveCompanions(of: oldPGN, to: url) }
            onRenamed?(oldID)
        }
    }

    private func removedByOthers() {
        guard !isClosed else { return }
        discard()
        onRemoved?()
    }

    // MARK: iCloud conflict versions

    /// Conflicting versions of the PGN are merged into the document, never lost; the merged
    /// PGN is written before the versions are removed.
    nonisolated private static func resolvePGNConflicts(_ core: RepertoireDoc, at url: URL, presenter: FilePresenter? = nil,
                                                        changed: (Changes) -> Void) throws {
        try FileAccess.resolveConflicts(at: url, presenter: presenter) { data in
            changed(core.mergeConflictVersion(text: String(decoding: data, as: UTF8.self)))
        } save: {
            try savePGN(core, to: url, presenter: presenter)
        }
    }

    /// Cards by latest review, settings by latest change (the core's `Sidecar::merged`).
    nonisolated private static func resolveSidecarConflicts(at url: URL, presenter: FilePresenter? = nil) throws {
        try FileAccess.resolveConflicts(at: url, presenter: presenter) { mergeSidecarData(a: $0, b: $1) }
    }

    /// The union of both logs by entry id.
    nonisolated private static func resolveRevlogConflicts(at url: URL, presenter: FilePresenter? = nil) throws {
        try FileAccess.resolveConflicts(at: url, presenter: presenter) { mergeRevlogData(a: $0, b: $1) }
    }

    /// The files and their presenters.
    private nonisolated struct Files: Sendable {
        var pgn: URL
        var sidecar: URL
        var presenters: Presenters?
        /// Set with `isDiscarded`, read by the writer as each operation runs: a save that was
        /// already on its way writes nothing once the files are being deleted.
        var discarded = false
        var revlog: URL { RepertoireLibrary.revlogURL(for: pgn) }
    }

    private nonisolated final class FileState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Files
        init(_ value: Files) { self.value = value }
        var current: Files { lock.withLock { value } }
        func update(_ body: (inout Files) -> Void) { lock.withLock { body(&value) } }
    }

    /// Runs file operations off the main actor, in the order they arrive.
    private actor Writer {
        func run<T: Sendable>(_ body: @Sendable () throws -> T) rethrows -> T { try body() }
    }

    /// Changes the core made by itself (stats arriving), from any thread.
    private nonisolated final class Listener: DocumentListener, @unchecked Sendable {
        weak var document: RepertoireDocument?
        init(document: RepertoireDocument) { self.document = document }
        func changed(changes: Changes) {
            Task { @MainActor [weak self] in self?.document?.apply(changes) }
        }
    }
}

// MARK: Read-only views of the core's state

extension RepertoireDocument {
    /// The move tree. Reading through the document registers the view for its changes.
    struct Tree {
        let core: RepertoireDoc
        let revision: UInt64

        subscript(id: NodeID) -> Node? { core.node(id: id) }
        var root: Node { core.root() }
        var count: Int { Int(core.count()) }
        var nodes: [Node] { core.allNodes() }

        func child(of id: NodeID, uci: String) -> NodeID? { core.childByUci(id: id, uci: uci) }
        func child(of id: NodeID, san: String) -> NodeID? { core.childBySan(id: id, san: san) }
        func path(to id: NodeID) -> [NodeID] { core.path(id: id) }
        func moves(to id: NodeID) -> [PlayedMove] { core.moves(id: id) }
        func subtree(of id: NodeID) -> [NodeID] { core.subtree(id: id) }
        func leaves(under id: NodeID) -> [NodeID] { core.leaves(id: id) }
        func isAncestor(_ a: NodeID, of b: NodeID) -> Bool { core.isAncestor(a: a, b: b) }
        func transpositionTarget(of id: NodeID) -> NodeID? { core.transpositionTarget(id: id) }
        func nodes(at epd: EPD) -> [NodeID] { core.nodesAt(epd: epd) }
        func node(followingUCI moves: [String], from start: NodeID = RepertoireTree.rootID) -> NodeID? {
            core.nodeFollowing(ucis: moves, start: start)
        }
        func position(of id: NodeID) -> Position? { core.position(id: id) }
        /// SAN line to a node, e.g. "1. e4 c5 2. Nf3".
        func lineText(to id: NodeID) -> String { core.lineText(id: id) }
    }

    struct Coverage {
        let core: RepertoireDoc
        let revision: UInt64

        subscript(id: NodeID) -> NodeCoverage? { core.coverage(id: id) }
        var root: NodeCoverage? { core.coverageRoot() }
        /// All gaps, biggest first.
        func gaps() -> [CoverageGap] { core.gaps() }
        /// Replies at a position that is not in the repertoire (a draft on the board).
        func replies(at epd: EPD, reach: Double?) -> [ReplyInfo]? { core.draftReplies(epd: epd, reach: reach) }
    }

    struct SidecarValues {
        let document: RepertoireDocument

        var studyCards: [EPD: Card] { document.studyCards }
        var color: Side { document.color }
        var database: ExplorerDatabase { document.database }
        var targetGames: Int { _ = document.revision; return Int(document.core.targetGames()) }
        var limits: DeckLimits? { _ = document.revision; return document.core.limits() }
        var practiceMode: PracticeMode? { _ = document.revision; return document.core.ownPracticeMode() }
        var lastLine: [String]? { document.core.lastLine() }

        /// When the next card falls due after today's are done.
        func nextDue(timing: SchedTiming) -> Date? {
            _ = document.revision
            return document.core.nextDue(timing: timing).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }

        func laterLearningDues(timing: SchedTiming) -> [Date] {
            _ = document.revision
            return document.core.laterLearningDues(timing: timing).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }

        func dueTomorrow(timing: SchedTiming) -> Int {
            _ = document.revision
            return Int(document.core.dueTomorrow(timing: timing))
        }
    }
}
