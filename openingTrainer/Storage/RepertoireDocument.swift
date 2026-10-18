import Foundation
import Observation
import OpeningCore

/// An open repertoire: the move tree from the PGN, the sidecar (settings and cards) and
/// the coverage engine. Every edit is written back to the PGN shortly after it happens,
/// and changes made on another device are merged in.
@Observable
final class RepertoireDocument {
    let entryID: String
    let pgnURL: URL
    let sidecarURL: URL
    private(set) var name: String

    private(set) var tree: RepertoireTree
    private(set) var sidecar: Sidecar
    private(set) var coverage: CoverageEngine
    /// Bumped on every change so views can refresh derived values.
    private(set) var revision = 0
    private(set) var saveError: String?
    private(set) var canUndo = false

    @ObservationIgnored private let store: StatsStore
    @ObservationIgnored private let queue: ExplorerQueue
    @ObservationIgnored private var undoStack: [RepertoireTree] = []
    @ObservationIgnored private var lastWrittenPGN = ""
    @ObservationIgnored private var lastWrittenSidecar = Data()
    @ObservationIgnored private var pgnSaveTask: Task<Void, Never>?
    @ObservationIgnored private var sidecarSaveTask: Task<Void, Never>?
    @ObservationIgnored private var presenters: [FilePresenter] = []
    @ObservationIgnored private var listener: UUID?
    @ObservationIgnored private var cachedTrainer: (revision: Int, trainer: Trainer)?

    /// Reads and parses the PGN off the main actor, since a large file takes a moment.
    nonisolated static func load(_ url: URL) async throws -> (text: String, tree: RepertoireTree) {
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            let text = String(decoding: try FileAccess.read(url), as: UTF8.self)
            return (text, RepertoireTree(pgn: text))
        }.value
    }

    /// `text` and `tree` come from `load(_:)`.
    init(entry: RepertoireEntry, text: String, tree: RepertoireTree, store: StatsStore, queue: ExplorerQueue) throws {
        guard let sidecar = entry.sidecar else { throw CocoaError(.fileNoSuchFile) }
        self.entryID = entry.id
        self.pgnURL = entry.pgnURL
        self.sidecarURL = entry.sidecarURL
        self.name = entry.name
        self.store = store
        self.queue = queue
        self.sidecar = sidecar
        self.coverage = CoverageEngine(settings: sidecar.coverageSettings)
        self.tree = tree
        lastWrittenPGN = text
        resolveConflicts()
        // The file repeats lines under every move order (e.g. a Chessbook export): write the
        // compact version, so later loads are fast.
        if tree.mergedTranspositions > 0 { schedulePGNSave() }

        store.load(sidecar.database)
        recomputeCoverage()

        listener = queue.subscribe { [weak self] epd, database in
            self?.statsArrived(epd, database)
        }
        let pgnPresenter = FilePresenter(url: pgnURL) { [weak self] in self?.pgnChangedOnDisk() }
        let sidecarPresenter = FilePresenter(url: sidecarURL) { [weak self] in self?.sidecarChangedOnDisk() }
        pgnPresenter.start()
        sidecarPresenter.start()
        presenters = [pgnPresenter, sidecarPresenter]
    }

    func close() {
        flush()
        for p in presenters { p.stop() }
        presenters = []
        if let listener { queue.unsubscribe(listener) }
        listener = nil
    }

    var color: Side { sidecar.color }
    var database: ExplorerDatabase { sidecar.database }
    var loadWarnings: [String] { tree.loadWarnings }

    // MARK: Stats

    func stats(_ epd: EPD) -> ExplorerStats? {
        store.stats(epd, sidecar.database)
    }

    /// Fetches stats for the position on screen, ahead of the coverage check.
    func requestStats(for epd: EPD) {
        queue.request(epd, sidecar.database, priority: 2)
    }

    /// Set while the repertoire is open in the builder. Only then is the coverage check run,
    /// so opening the Train tab never starts fetching.
    @ObservationIgnored private var checksCoverage = false

    /// Starts the background coverage check. It only asks for opponent-to-move positions
    /// you would meet at least once in N games (N = your target), most frequent first, and
    /// each answer tells which positions below are frequent enough to need a request. So
    /// the number of requests depends on the target, not on the size of the PGN.
    func startCoverageCheck() {
        checksCoverage = true
        checkCoverage()
    }

    func stopCoverageCheck() {
        checksCoverage = false
        queue.cancelAll(for: sidecar.database)
    }

    private func checkCoverage() {
        guard checksCoverage else { return }
        for (epd, reach) in coverage.pendingPositions(tree: tree) {
            queue.request(epd, sidecar.database, priority: reach)
        }
    }

    /// Opponent positions above your target whose stats are not loaded yet.
    var uncheckedPositions: Int { coverage.root?.pendingCount ?? 0 }

    private func statsArrived(_ epd: EPD, _ database: ExplorerDatabase) {
        guard database == sidecar.database else { return }
        coverage.statsArrived(for: epd, tree: tree, stats: lookup)
        revision += 1
        checkCoverage()
        scheduleSidecarSave(delay: 5)
    }

    private var lookup: CoverageEngine.StatsLookup {
        let store = store
        let database = sidecar.database
        return { store.stats($0, database) }
    }

    private func recomputeCoverage() {
        coverage = CoverageEngine(settings: sidecar.coverageSettings)
        coverage.recomputeAll(tree: tree, stats: lookup)
        revision += 1
        checkCoverage()
    }

    // MARK: Edits

    @discardableResult
    func addMove(_ uci: String, after parent: NodeID) -> NodeID? {
        if let existing = tree.child(of: parent, uci: uci) { return existing }
        var result: NodeID?
        perform(changedAt: parent) { tree in
            result = tree.addMove(uci, after: parent)
            return result.flatMap { tree[$0]?.epd }.map { [$0] } ?? []
        }
        return result
    }

    /// Adds moves one after another; returns the last node.
    @discardableResult
    func addLine(_ ucis: [String], after start: NodeID) -> NodeID? {
        guard !ucis.isEmpty else { return start }
        if let existing = tree.node(following: ucis, from: start) { return existing }
        var result: NodeID?
        perform(changedAt: start) { tree in
            result = tree.addLine(ucis, after: start)
            return Set(tree.subtree(of: start).compactMap { tree[$0]?.epd })
        }
        return result
    }

    func delete(_ id: NodeID) {
        guard let parent = tree[id]?.parent else { return }
        perform(changedAt: parent) { tree in
            let removed = Set(tree.subtree(of: id).compactMap { tree[$0]?.epd })
            tree.delete(id)
            return removed
        }
    }

    func promote(_ id: NodeID) {
        guard let parent = tree[id]?.parent else { return }
        perform(changedAt: parent) { tree in
            tree.promote(id)
            return Set(tree.subtree(of: parent).compactMap { tree[$0]?.epd })
        }
    }

    func setNote(_ text: String, for id: NodeID) {
        guard tree[id]?.note != text else { return }
        undoStack.append(tree)
        tree.setNote(text, for: id)
        didEdit()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        tree = previous
        coverage.recomputeAll(tree: tree, stats: lookup)
        canUndo = !undoStack.isEmpty
        revision += 1
        checkCoverage()
        schedulePGNSave()
    }

    private func perform(changedAt node: NodeID, _ edit: (inout RepertoireTree) -> Set<EPD>) {
        let before = tree
        var working = tree
        let epds = edit(&working)
        guard working.count != before.count || working.root.children != before.root.children
                || working[node]?.children != before[node]?.children else { return }
        undoStack.append(before)
        if undoStack.count > 100 { undoStack.removeFirst() }
        tree = working
        coverage.update(changedAt: node, epds: epds, tree: tree, stats: lookup)
        didEdit()
    }

    private func didEdit() {
        canUndo = !undoStack.isEmpty
        revision += 1
        checkCoverage()
        schedulePGNSave()
        scheduleSidecarSave(delay: 3)
    }

    // MARK: Settings and training

    func updateSettings(color: Side, database: ExplorerDatabase, targetGames: Int, minGames: Int) {
        let databaseChanged = database != sidecar.database
        if databaseChanged { queue.cancelAll(for: sidecar.database) }
        sidecar.color = color
        sidecar.database = database
        sidecar.targetGames = targetGames
        sidecar.minGames = minGames
        sidecar.settingsModified = .now
        store.load(database)
        recomputeCoverage()
        scheduleSidecarSave(delay: 0.5)
    }

    /// Excludes an opponent move at `node`'s position from coverage, or includes it again.
    /// Applies wherever the position occurs.
    func setExcluded(_ uci: String, at node: NodeID, _ excluded: Bool) {
        guard let epd = tree[node]?.epd, sidecar.isExcluded(uci, at: epd) != excluded else { return }
        sidecar.setExcluded(uci, at: epd, excluded)
        coverage.settings = sidecar.coverageSettings
        coverage.exclusionsChanged(at: epd, tree: tree, stats: lookup)
        revision += 1
        scheduleSidecarSave(delay: 0.5)
    }

    func rememberLine(_ ucis: [String]) {
        guard sidecar.lastLine != ucis else { return }
        sidecar.lastLine = ucis
        scheduleSidecarSave(delay: 3)
    }

    var trainer: Trainer {
        if let cachedTrainer, cachedTrainer.revision == revision { return cachedTrainer.trainer }
        let trainer = Trainer(tree: tree, color: sidecar.color)
        cachedTrainer = (revision, trainer)
        return trainer
    }

    func record(_ grades: [EPD: Grade]) {
        guard !grades.isEmpty else { return }
        DrillSession.apply(grades, to: &sidecar.cards)
        revision += 1
        scheduleSidecarSave(delay: 1)
    }

    func learningProgress(under node: NodeID = RepertoireTree.rootID) -> Trainer.Progress {
        trainer.progress(under: node, cards: sidecar.cards)
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
    }

    private func schedulePGNSave() {
        pgnSaveTask?.cancel()
        pgnSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.pgnSaveTask = nil
            self.savePGN()
        }
    }

    private func scheduleSidecarSave(delay: Double) {
        sidecarSaveTask?.cancel()
        sidecarSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.sidecarSaveTask = nil
            self.saveSidecar()
        }
    }

    private func savePGN() {
        let text = tree.pgnText()
        guard text != lastWrittenPGN else { return }
        do {
            try FileAccess.write(Data(text.utf8), to: pgnURL, presenter: presenters.first)
            lastWrittenPGN = text
            saveError = nil
        } catch {
            saveError = "Could not save \(pgnURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func saveSidecar() {
        let progress = learningProgress()
        let root = coverage.root
        sidecar.summary = Sidecar.Summary(
            completion: root?.completion ?? 0, gapCount: root?.gapCount ?? 0,
            cardCount: progress.cards, matureCount: progress.mature, dueCount: progress.due,
            configKey: sidecar.configKey, computedAt: .now)
        guard let data = try? sidecar.encoded(), data != lastWrittenSidecar else { return }
        do {
            try FileAccess.write(data, to: sidecarURL, presenter: presenters.last)
            lastWrittenSidecar = data
        } catch {
            saveError = "Could not save training data: \(error.localizedDescription)"
        }
    }

    // MARK: Changes from elsewhere

    private func pgnChangedOnDisk() {
        guard let data = try? FileAccess.read(pgnURL) else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard text != lastWrittenPGN else { return }
        let remote = RepertoireTree(pgn: text)
        if pgnSaveTask != nil {
            // Local edits not written yet: keep both sides.
            tree.merge(tree: remote)
        } else {
            tree = remote
            lastWrittenPGN = text
        }
        resolveConflicts()
        undoStack = []
        canUndo = false
        coverage.recomputeAll(tree: tree, stats: lookup)
        revision += 1
        checkCoverage()
        if pgnSaveTask != nil || tree.pgnText() != text { schedulePGNSave() }
    }

    private func sidecarChangedOnDisk() {
        guard let data = try? FileAccess.read(sidecarURL), data != lastWrittenSidecar,
              let remote = try? Sidecar.decode(data) else { return }
        let settingsBefore = sidecar.configKey
        let excludedBefore = sidecar.excludedMoves
        sidecar = sidecar.merged(with: remote)
        lastWrittenSidecar = data
        if sidecar.configKey != settingsBefore {
            store.load(sidecar.database)
            recomputeCoverage()
        } else if sidecar.excludedMoves != excludedBefore {
            recomputeCoverage()
        } else {
            revision += 1
        }
    }

    private func resolveConflicts() {
        var merged = false
        FileAccess.resolveConflicts(at: pgnURL) { data in
            tree.merge(tree: RepertoireTree(pgn: String(decoding: data, as: UTF8.self)))
            merged = true
        }
        if merged { schedulePGNSave() }
    }
}

extension RepertoireTree {
    /// Follows UCI moves from `start`; nil if any is missing.
    func node(following ucis: [String], from start: NodeID) -> NodeID? {
        var cursor = start
        for uci in ucis {
            guard let next = child(of: cursor, uci: uci) else { return nil }
            cursor = next
        }
        return cursor
    }

    /// SAN line to a node, e.g. "1. e4 c5 2. Nf3".
    func lineText(to id: NodeID) -> String {
        let path = path(to: id).dropFirst()
        var parts: [String] = []
        for nodeID in path {
            guard let node = self[nodeID], let move = node.move else { continue }
            let ply = node.ply - 1
            if ply % 2 == 0 { parts.append("\(ply / 2 + 1).") } else if parts.isEmpty { parts.append("\(ply / 2 + 1)...") }
            parts.append(move.san)
        }
        return parts.joined(separator: " ")
    }
}
