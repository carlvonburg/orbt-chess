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
    private(set) var pgnURL: URL
    private(set) var sidecarURL: URL
    private(set) var name: String

    let core: RepertoireDoc
    /// Bumped on every change so views can refresh derived values.
    private(set) var revision: UInt64 = 0
    private(set) var saveError: String?
    private(set) var canUndo = false

    @ObservationIgnored let explorer: ExplorerService
    @ObservationIgnored private var lastWrittenSidecar = Data()
    @ObservationIgnored private var pgnSaveTask: Task<Void, Never>?
    @ObservationIgnored private var sidecarSaveTask: Task<Void, Never>?
    @ObservationIgnored private var presenters: [FilePresenter] = []
    @ObservationIgnored private var cachedCards: (revision: UInt64, cards: [EPD: Card])?

    /// Reads the PGN off the main actor, since a large file takes a moment to download.
    nonisolated static func load(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return String(decoding: try FileAccess.read(url), as: UTF8.self)
        }.value
    }

    /// `text` comes from `load(_:)`.
    init(entry: RepertoireEntry, text: String, explorer: ExplorerService) throws {
        guard let sidecar = entry.sidecarData else { throw CocoaError(.fileNoSuchFile) }
        self.entryID = entry.id
        self.pgnURL = entry.pgnURL
        self.sidecarURL = entry.sidecarURL
        self.name = entry.name
        self.explorer = explorer
        let opened = try openRepertoire(pgnText: text, sidecar: sidecar, defaults: TrainingDefaults.studyDefaults,
                                        explorer: explorer.core)
        core = opened.document
        lastWrittenSidecar = sidecar
        core.setListener(listener: Listener(document: self))
        apply(opened.changes)
        resolveConflicts()
        startPresenters()
    }

    /// Applies what the core changed: refreshes views and schedules the saves it asks for.
    func apply(_ changes: Changes) {
        if changes.revision != revision { revision = changes.revision }
        canUndo = core.canUndo()
        if let ms = changes.savePgnAfterMs { schedulePGNSave(after: ms) }
        if let ms = changes.saveSidecarAfterMs { scheduleSidecarSave(after: ms) }
        cachedCards = nil
    }

    private func startPresenters() {
        let pgnPresenter = FilePresenter(url: pgnURL) { [weak self] in self?.pgnChangedOnDisk() }
        let sidecarPresenter = FilePresenter(url: sidecarURL) { [weak self] in self?.sidecarChangedOnDisk() }
        pgnPresenter.start()
        sidecarPresenter.start()
        presenters = [pgnPresenter, sidecarPresenter]
    }

    private func stopPresenters() {
        for p in presenters { p.stop() }
        presenters = []
    }

    /// Renames the PGN and sidecar. The entry id changes with the file names.
    func rename(to newName: String, in library: RepertoireLibrary) throws {
        flush()
        stopPresenters()
        defer { startPresenters() }
        let entry = try library.rename(pgn: pgnURL, to: newName)
        entryID = entry.id
        pgnURL = entry.pgnURL
        sidecarURL = entry.sidecarURL
        name = entry.name
    }

    func close() {
        flush()
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

    // MARK: Settings and training

    func updateSettings(color: Side, database: ExplorerDatabase, targetGames: Int, minGames: Int) {
        apply(core.updateSettings(color: color, database: database, targetGames: Int64(targetGames),
                                  minGames: Int64(minGames), now: .of(.now)))
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

    /// The whole review log, including answers not written yet.
    func reviewLog() -> [RevlogEntry] {
        core.reviewLog(onDisk: (try? FileAccess.read(revlogURL)) ?? Data())
    }

    // MARK: Saving

    /// Writes pending changes immediately (on close or when the app goes to background).
    func flush() {
        if pgnSaveTask != nil {
            pgnSaveTask?.cancel()
            pgnSaveTask = nil
            savePGN()
        }
        if sidecarSaveTask != nil {
            sidecarSaveTask?.cancel()
            sidecarSaveTask = nil
            saveSidecar()
        }
        saveRevlog()
    }

    private func schedulePGNSave(after ms: UInt32) {
        pgnSaveTask?.cancel()
        pgnSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(ms)))
            guard !Task.isCancelled, let self else { return }
            self.pgnSaveTask = nil
            self.savePGN()
        }
    }

    private func scheduleSidecarSave(after ms: UInt32) {
        sidecarSaveTask?.cancel()
        sidecarSaveTask = Task { [weak self] in
            if ms > 0 { try? await Task.sleep(for: .milliseconds(Int(ms))) }
            guard !Task.isCancelled, let self else { return }
            self.sidecarSaveTask = nil
            self.saveSidecar()
        }
    }

    private func savePGN() {
        guard let text = core.pgnToSave() else { return }
        do {
            try FileAccess.write(Data(text.utf8), to: pgnURL, presenter: presenters.first)
            core.pgnSaved(text: text)
            saveError = nil
        } catch {
            saveError = "Could not save \(pgnURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func saveRevlog() {
        guard let lines = core.revlogToAppend() else { return }
        do {
            try FileAccess.append(lines, to: revlogURL)
            core.revlogAppended()
        } catch {
            saveError = "Could not save the review log: \(error.localizedDescription)"
        }
    }

    private func saveSidecar() {
        saveRevlog()
        guard let data = core.sidecarToSave(timing: SchedTiming(), now: .of(.now)) else { return }
        do {
            try FileAccess.write(data, to: sidecarURL, presenter: presenters.last)
            core.sidecarSaved(data: data)
            lastWrittenSidecar = data
        } catch {
            saveError = "Could not save training data: \(error.localizedDescription)"
        }
    }

    // MARK: Changes from elsewhere

    private func pgnChangedOnDisk() {
        guard let data = try? FileAccess.read(pgnURL) else { return }
        apply(core.remotePgn(text: String(decoding: data, as: UTF8.self)))
        resolveConflicts()
    }

    private func sidecarChangedOnDisk() {
        guard let data = try? FileAccess.read(sidecarURL), data != lastWrittenSidecar else { return }
        apply(core.remoteSidecar(data: data))
    }

    /// Conflicting iCloud versions of the PGN are merged in, never lost.
    private func resolveConflicts() {
        FileAccess.resolveConflicts(at: pgnURL) { data in
            apply(core.mergeConflictVersion(text: String(decoding: data, as: UTF8.self)))
        }
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
        var minGames: Int { _ = document.revision; return Int(document.core.minGames()) }
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
