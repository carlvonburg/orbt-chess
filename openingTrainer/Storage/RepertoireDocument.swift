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
    let isConnected: Bool
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
    @ObservationIgnored private var accessingScope = false
    @ObservationIgnored private var cachedTrainer: (revision: Int, trainer: Trainer)?

    init(entry: RepertoireEntry, store: StatsStore, queue: ExplorerQueue) throws {
        guard let pgnURL = entry.pgnURL, let sidecar = entry.sidecar else { throw CocoaError(.fileNoSuchFile) }
        self.entryID = entry.id
        self.pgnURL = pgnURL
        self.sidecarURL = entry.sidecarURL
        self.isConnected = entry.isConnected
        self.name = entry.name
        self.store = store
        self.queue = queue
        self.sidecar = sidecar
        self.coverage = CoverageEngine(settings: sidecar.coverageSettings)
        self.tree = RepertoireTree()

        if isConnected { accessingScope = pgnURL.startAccessingSecurityScopedResource() }
        try? FileManager.default.startDownloadingUbiquitousItem(at: pgnURL)
        let text = String(decoding: try FileAccess.read(pgnURL), as: UTF8.self)
        lastWrittenPGN = text
        tree = RepertoireTree(pgn: text)
        resolveConflicts()

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
        if accessingScope { pgnURL.stopAccessingSecurityScopedResource() }
        accessingScope = false
    }

    var color: Side { sidecar.color }
    var database: ExplorerDatabase { sidecar.database }
    var loadWarnings: [String] { tree.loadWarnings }

    // MARK: Stats

    func stats(_ epd: EPD) -> ExplorerStats? {
        store.stats(epd, sidecar.database)
    }

    /// Fetches stats for a position the user is looking at. This is the only place stats
    /// are requested: nothing is fetched in the background, so a large PGN never turns into
    /// a burst of explorer requests. Coverage uses whatever is cached.
    func requestStats(for epd: EPD) {
        queue.request(epd, sidecar.database, priority: 1)
    }

    private func statsArrived(_ epd: EPD, _ database: ExplorerDatabase) {
        guard database == sidecar.database else { return }
        coverage.statsArrived(for: epd, tree: tree, stats: lookup)
        revision += 1
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

    /// Merges pasted PGN. Lines that start from the initial position are merged at the root,
    /// otherwise at `node`. Returns the number of new moves.
    @discardableResult
    func mergePGN(_ text: String, at node: NodeID) -> Int {
        let games = PGNParser.parse(text)
        guard !games.isEmpty else { return 0 }
        var added = 0
        perform(changedAt: RepertoireTree.rootID) { tree in
            for game in games {
                var probe = tree
                let atRoot = probe.merge(game.moves, at: RepertoireTree.rootID)
                let rootWarnings = probe.loadWarnings.count - tree.loadWarnings.count
                if rootWarnings == 0 || node == RepertoireTree.rootID {
                    tree = probe
                    added += atRoot
                } else {
                    added += tree.merge(game.moves, at: node)
                }
            }
            return Set(tree.nodes.values.map(\.epd))
        }
        return added
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        tree = previous
        coverage.recomputeAll(tree: tree, stats: lookup)
        canUndo = !undoStack.isEmpty
        revision += 1
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
        if pgnSaveTask != nil || tree.pgnText() != text { schedulePGNSave() }
    }

    private func sidecarChangedOnDisk() {
        guard let data = try? FileAccess.read(sidecarURL), data != lastWrittenSidecar,
              let remote = try? Sidecar.decode(data) else { return }
        let settingsBefore = sidecar.configKey
        sidecar = sidecar.merged(with: remote)
        lastWrittenSidecar = data
        if sidecar.configKey != settingsBefore {
            store.load(sidecar.database)
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
