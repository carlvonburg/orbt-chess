import Foundation
import Observation
import OpeningCore

/// An open repertoire: the move tree from the PGN, the sidecar (settings and cards) and
/// the coverage engine. Every edit is written back to the PGN shortly after it happens,
/// and changes made on another device are merged in.
@Observable
final class RepertoireDocument {
    private(set) var entryID: String
    private(set) var pgnURL: URL
    private(set) var sidecarURL: URL
    private(set) var name: String

    private(set) var tree: RepertoireTree {
        didSet { treeVersion += 1 }
    }
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
    /// Bumped whenever the tree changes. The trainer and the card positions depend only on the
    /// tree and your color, so answering a move (which bumps `revision`) keeps them.
    @ObservationIgnored private var treeVersion = 0
    @ObservationIgnored private var cachedTrainer: (treeVersion: Int, color: Side, trainer: Trainer)?
    @ObservationIgnored private var cachedCardSets: (treeVersion: Int, color: Side, cards: Set<EPD>, suspended: Int)?
    @ObservationIgnored private var cachedProgress: (revision: Int, progress: Trainer.Progress)?
    @ObservationIgnored private var cachedCounts: (revision: Int, minute: Int64, counts: CardQueues.Counts)?
    /// Answers not yet appended to the review log.
    @ObservationIgnored private var pendingRevlog: [RevlogEntry] = []

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
        startPresenters()
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

    /// The opening name of a node, or of its nearest ancestor, from stats already loaded.
    func openingName(at id: NodeID) -> String? {
        var cursor: NodeID? = id
        while let id = cursor, let n = tree[id] {
            if let name = stats(n.epd)?.opening?.name { return name }
            cursor = n.parent
        }
        return nil
    }

    /// Fetches stats for the position on screen, ahead of the coverage check.
    func requestStats(for epd: EPD) {
        queue.focus(epd, sidecar.database)
    }

    /// How many screens of this repertoire are showing (overview, builder, study). The
    /// coverage check runs while any is, so the library and the other tabs never fetch.
    @ObservationIgnored private var coverageViewers = 0

    /// Starts the background coverage check. It only asks for opponent-to-move positions
    /// you would meet at least once in N games (N = your target), most frequent first, and
    /// each answer tells which positions below are frequent enough to need a request. So
    /// the number of requests depends on the target, not on the size of the PGN.
    func startCoverageCheck() {
        coverageViewers += 1
        checkCoverage()
    }

    func stopCoverageCheck() {
        coverageViewers = max(coverageViewers - 1, 0)
        if coverageViewers == 0 { queue.cancelAll(for: sidecar.database) }
    }

    private func checkCoverage() {
        guard coverageViewers > 0 else { return }
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
        syncSuspension()
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
        syncSuspension()
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
        syncSuspension()
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
        checkCoverage()
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
        if let cachedTrainer, cachedTrainer.treeVersion == treeVersion, cachedTrainer.color == sidecar.color {
            return cachedTrainer.trainer
        }
        let trainer = Trainer(tree: tree, color: sidecar.color)
        cachedTrainer = (treeVersion, sidecar.color, trainer)
        return trainer
    }

    var revlogURL: URL { RepertoireLibrary.revlogURL(for: pgnURL) }

    /// The whole repertoire's progress is read by the list, the overview and every save, so it
    /// is computed once per change; the card positions behind it once per tree change.
    func learningProgress(under node: NodeID = RepertoireTree.rootID) -> Trainer.Progress {
        guard node == RepertoireTree.rootID else { return trainer.progress(under: node, cards: sidecar.studyCards) }
        if let cachedProgress, cachedProgress.revision == revision { return cachedProgress.progress }
        let sets: (cards: Set<EPD>, suspended: Int)
        if let cached = cachedCardSets, cached.treeVersion == treeVersion, cached.color == sidecar.color {
            sets = (cached.cards, cached.suspended)
        } else {
            let trainer = trainer
            sets = (trainer.cardEPDSet, trainer.suspendedCardEPDs().count)
            cachedCardSets = (treeVersion, sidecar.color, sets.cards, sets.suspended)
        }
        var progress = Trainer.Progress(suspended: sets.suspended)
        for epd in sets.cards {
            progress.cards += 1
            if let card = sidecar.studyCards[epd] { progress.add(card) }
        }
        cachedProgress = (revision, progress)
        return progress
    }

    /// Every move in the PGN, both sides.
    var savedMoveCount: Int { max(0, tree.count - 1) }

    // MARK: Study (Anki)

    /// The default preset; per-repertoire limits are applied by `remainingLimits`.
    var deckConfig: DeckConfig { TrainingDefaults.config }
    var scheduler: Scheduler { Scheduler(config: deckConfig) }
    var practiceMode: PracticeMode { sidecar.practiceMode ?? TrainingDefaults.practiceMode }

    func remainingLimits(_ timing: SchedTiming) -> RemainingLimits {
        RemainingLimits(config: deckConfig, limits: sidecar.limits ?? DeckLimits(),
                        stats: sidecar.studyStats ?? DeckStudyStats(), today: timing.daysElapsed)
    }

    /// How often each position is reached, for ordering new cards and reviews.
    var reach: [NodeID: Double] {
        var result: [NodeID: Double] = [:]
        for id in tree.subtree(of: RepertoireTree.rootID) {
            if let r = coverage[id]?.reach { result[id] = r }
        }
        return result
    }

    func studySession(branch: NodeID? = nil, timing: SchedTiming = SchedTiming()) -> StudySession {
        if let branch {
            return StudySession(trainer: trainer, mode: practiceMode, branch: branch, cards: sidecar.studyCards,
                                timing: timing, learnAheadSecs: deckConfig.learnAheadSecs, reach: reach)
        }
        return StudySession(trainer: trainer, mode: practiceMode, cards: sidecar.studyCards, limits: remainingLimits(timing),
                            timing: timing, learnAheadSecs: deckConfig.learnAheadSecs, reach: reach)
    }

    /// Today's New / Learning / To Review counts, as on Anki's deck overview.
    func studyCounts(timing: SchedTiming = SchedTiming()) -> CardQueues.Counts {
        let minute = timing.now / 60
        if let cachedCounts, cachedCounts.revision == revision, cachedCounts.minute == minute { return cachedCounts.counts }
        let counts = studySession(timing: timing).queue.counts
        cachedCounts = (revision, minute, counts)
        return counts
    }

    /// Answers a card and logs it. Answers outside today's queue (a branch session or a review
    /// ahead) don't count toward the daily limits, as in an Anki filtered deck.
    @discardableResult
    func answer(_ epd: EPD, position: Int, rating: Rating, filtered: Bool, takenMillis: Int,
                timing: SchedTiming = SchedTiming()) -> Card {
        let result = scheduler.answer(sidecar.studyCards[epd], epd: epd, position: position, rating: rating,
                                      timing: timing, filtered: filtered, takenMillis: takenMillis)
        sidecar.studyCards[epd] = result.card
        if !filtered {
            var stats = sidecar.studyStats ?? DeckStudyStats()
            stats.recordAnswer(fromQueue: result.fromQueue, millis: result.revlog.time, today: timing.daysElapsed)
            sidecar.studyStats = stats
        }
        pendingRevlog.append(result.revlog)
        revision += 1
        scheduleSidecarSave(delay: 1)
        return result.card
    }

    /// Anki's custom study "Increase today's new card limit".
    func extendNewLimitToday(by count: Int, timing: SchedTiming = SchedTiming()) {
        extendLimitsToday(new: count, review: 0, timing: timing)
    }

    /// Anki's custom study "Increase today's review card limit".
    func extendReviewLimitToday(by count: Int, timing: SchedTiming = SchedTiming()) {
        extendLimitsToday(new: 0, review: count, timing: timing)
    }

    /// Reviews due today beyond today's review limit (what Anki's custom study shows as
    /// "N more available").
    func reviewsBeyondLimit(timing: SchedTiming = SchedTiming()) -> Int {
        let due = sidecar.studyCards.filter { epd, card in
            (card.queue == .review || card.queue == .dayLearn) && card.due <= Int64(timing.daysElapsed)
                && trainer.cardEPDSet.contains(epd)
        }.count
        return max(0, due - studyCounts(timing: timing).review)
    }

    private func extendLimitsToday(new: Int, review: Int, timing: SchedTiming) {
        var stats = sidecar.studyStats ?? DeckStudyStats()
        stats.extendLimits(today: timing.daysElapsed, new: new, review: review)
        sidecar.studyStats = stats
        revision += 1
        scheduleSidecarSave(delay: 0.5)
    }

    /// Daily limits ("This deck") and practice mode for this repertoire.
    func updateStudySettings(limits: DeckLimits, practiceMode: PracticeMode?) {
        sidecar.limits = limits.isEmpty ? nil : limits
        sidecar.practiceMode = practiceMode
        sidecar.settingsModified = .now
        revision += 1
        scheduleSidecarSave(delay: 0.5)
    }

    /// The whole review log, including answers not written yet.
    func reviewLog() -> [RevlogEntry] {
        let onDisk = (try? FileAccess.read(revlogURL)).map(RevlogFile.decode) ?? []
        return RevlogFile.merged(onDisk, pendingRevlog)
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

    private func saveRevlog() {
        guard !pendingRevlog.isEmpty else { return }
        do {
            try FileAccess.append(RevlogFile.encode(pendingRevlog), to: revlogURL)
            pendingRevlog = []
        } catch {
            saveError = "Could not save the review log: \(error.localizedDescription)"
        }
    }

    private func saveSidecar() {
        saveRevlog()
        let progress = learningProgress()
        let root = coverage.root
        sidecar.summary = Sidecar.Summary(
            completion: root?.completion ?? 0, gapCount: root?.gapCount ?? 0,
            cardCount: progress.cards, matureCount: progress.mature, savedMoveCount: savedMoveCount,
            suspendedCount: progress.suspended, dueCount: studyCounts().review,
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
        syncSuspension()
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
        // The other device's cards may have been suspended against its own copy of the PGN.
        syncSuspension()
    }

    /// Suspends cards below alternative moves and restores the main line's (Anki's suspend).
    private func syncSuspension() {
        guard sidecar.syncSuspension(active: trainer.cardEPDs()) else { return }
        revision += 1
        scheduleSidecarSave(delay: 1)
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
