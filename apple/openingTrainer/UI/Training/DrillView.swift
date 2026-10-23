import OpeningCoreRust
import SwiftUI

extension DrillMode {
    var title: String {
        switch self {
        case .study: "Study"
        case .branch: "Study Branch"
        }
    }
}

/// Plays study lines one after another. The Rust core (`DrillSession`) answers the cards and
/// decides what happens next; this runs its timers: the rewind and the opponent's moves step
/// on a clock, the next line follows a finished one after a pause, and a wrong move's
/// feedback turns into a hint after a moment.
@Observable
final class DrillModel {
    let document: RepertoireDocument
    let mode: DrillMode
    /// New moves to add to today's limit before studying (Anki's custom study).
    let learnMore: Int
    @ObservationIgnored private let session: DrillSession
    @ObservationIgnored private var started = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var wrongTimer: Task<Void, Never>?
    @ObservationIgnored private var badgeTimer: Task<Void, Never>?
    /// Bumped after every change, so views re-read the session.
    private var stamp = 0

    init(document: RepertoireDocument, mode: DrillMode, learnMore: Int = 0) {
        self.document = document
        self.mode = mode
        self.learnMore = learnMore
        session = DrillSession(doc: document.core, mode: mode)
    }

    private func observe() {
        _ = stamp
        _ = document.revision
    }

    private static var nowMs: Int64 { ExplorerService.millis(.now) }

    var color: Side { document.color }
    var isFiltered: Bool { session.isFiltered() }
    var phase: Phase { observe(); return session.phase() }
    var finished: Bool { phase == .finished }
    var feedback: Feedback { observe(); return session.feedback() }
    var showHint: Bool { observe(); return session.showHint() }
    /// Cards answered in this session.
    var answeredCount: Int { observe(); return Int(session.answeredCount()) }
    /// Of those, answered Good.
    var correctCount: Int { observe(); return Int(session.correctCount()) }
    /// Time spent answering: the sum of each answer's time, as in the review log.
    var studiedMillis: Int { observe(); return Int(session.studiedMillis()) }
    var counts: Counts { observe(); return session.counts() }
    var nextLearningDue: Date? {
        observe()
        return session.nextLearningDue().map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    var position: ChessPosition { observe(); return wrongMove?.position ?? session.position() }
    var lastMove: PlayedMove? { observe(); return wrongMove?.mv ?? session.lastMove() }
    /// The moves on the board, from the start of the line.
    var playedNodes: [NodeID] { observe(); return session.playedNodes() }
    var openingName: String? {
        observe()
        return session.currentNode().flatMap { document.openingName(at: $0) }
    }
    var isUserTurn: Bool { observe(); return session.isUserTurn() }
    /// Whether the board takes a move: your turn, and no wrong move still on it.
    var canMove: Bool { isUserTurn && wrongMove == nil }

    /// The kind of card being asked, for highlighting its count.
    var askedKind: QueueKind? { observe(); return session.askedKind() }

    var arrows: [BoardArrow] { observe(); return wrongMove == nil ? session.arrows().map(BoardArrow.init) : [] }
    /// A tick or cross on the square the last answer moved to, shown for a moment.
    private(set) var badge: BoardBadge?
    /// A wrong move, left on the board for a moment before it is taken back.
    private var wrongMove: PlayResult?

    func start() {
        // Runs again when the view reappears (after browsing, or as it's pushed): resume the
        // opponent's moves if they were stopped, keep the session.
        if !started {
            started = true
            document.apply(session.start(learnMore: Int64(learnMore), timing: SchedTiming()))
        }
        changed()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func userMoved(from: BoardSquare, to: BoardSquare, promotion: PieceKind?) {
        document.apply(session.userMoved(from: from, to: to, promotion: promotion, timing: SchedTiming(), nowMs: Self.nowMs))
        switch session.feedback() {
        case .correct: showBadge(.correct, on: to)
        case .wrong:
            showBadge(.wrong, on: to)
            wrongMove = session.position().play(from: from, to: to, promotion: promotion)
        default: break
        }
        if case .wrong = session.feedback() {
            wrongTimer?.cancel()
            wrongTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled, let self else { return }
                // Anki shows the answer: keep the arrow until the move is played
                self.session.wrongTimeout()
                self.stamp += 1
            }
        }
        changed(afterMove: true)
    }

    /// Shows the badge, and takes back a wrong move with it.
    private func showBadge(_ kind: BoardBadge.Kind, on square: BoardSquare) {
        badge = BoardBadge(square: square, kind: kind)
        badgeTimer?.cancel()
        badgeTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            self.badge = nil
            self.wrongMove = nil
        }
    }

    /// The node to open when the user browses the repertoire mid-line. Browsing on your
    /// own turn reveals the answer, so it counts as Again.
    func browseNode() -> NodeID? {
        let result = session.browseNode(timing: SchedTiming(), nowMs: Self.nowMs)
        document.apply(result.changes)
        changed()
        return result.node
    }

    func hint() {
        document.apply(session.hint(timing: SchedTiming(), nowMs: Self.nowMs))
        changed()
    }

    /// The moves to the board, for the analysis board. Looking counts as Again, like browsing.
    func analysisMoves() -> [PlayedMove] {
        let result = session.analysisMoves(timing: SchedTiming(), nowMs: Self.nowMs)
        document.apply(result.changes)
        changed()
        return result.moves
    }

    /// Anki's custom study "Increase today's new card limit".
    func increaseNewLimit(by count: Int) {
        document.apply(session.extendLimits(new: Int64(count), review: 0, timing: SchedTiming()))
        changed()
    }

    /// Anki's custom study "Increase today's review card limit".
    func increaseReviewLimit(by count: Int) {
        document.apply(session.extendLimits(new: 0, review: Int64(count), timing: SchedTiming()))
        changed()
    }

    /// Looks for cards again (learning cards that became due).
    func checkAgain() {
        session.checkAgain(timing: SchedTiming())
        changed()
    }

    // MARK: Timing

    /// Refreshes the views and runs the timer the new phase needs.
    /// `afterMove`: the user just played, so the reply waits a little longer than the moves
    /// played on the way to their turn.
    private func changed(afterMove: Bool = false) {
        stamp += 1
        timer?.cancel()
        timer = nil
        let delay: Int
        switch session.phase() {
        case .rewinding: delay = 250
        case .autoplay: delay = afterMove ? 600 : 450
        case .lineDone: delay = 400
        case .idle, .userTurn, .finished: return
        }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            // The badge outlasts the opponent's reply, not the line.
            if self.session.phase() != .autoplay { self.badge = nil }
            if self.session.phase() == .lineDone {
                self.session.nextLine(timing: SchedTiming())
            } else {
                self.session.step(nowMs: Self.nowMs)
            }
            self.changed()
        }
    }
}

struct DrillView: View {
    /// In the split view (iPad, Mac) the board is in the board column and this is the panel.
    @Environment(\.inSplitView) private var inSplitView
    @Environment(\.openScreen) private var openScreen
    let model: DrillModel
    @State private var browsing: BrowseRequest?

    private struct BrowseRequest: Hashable {
        let node: NodeID
    }

    @State private var analysis: AnalysisModel?

    /// The next repertoire when studying all of them: its name and how to go on.
    private let next: (name: String, start: () -> Void)?

    /// Pushed onto the caller's navigation stack (Study Now, Study Branch, Study All). The
    /// library makes the model before pushing the screen (`LibraryScreens`); elsewhere
    /// `DrillScreen` owns it.
    init(model: DrillModel, next: (name: String, start: () -> Void)? = nil) {
        self.model = model
        self.next = next
    }

    var body: some View {
        content
            .hidesTabBar()
            .task { model.start() }
        // Browsing pushes the builder on top; training goes on when it's popped.
        .onDisappear { if browsing == nil { model.stop() } }
        .checksCoverage(model.document)
        .analysisBoard($analysis)
    }

    private var content: some View {
        Group {
            if model.finished {
                StudyFinishedView(model: model, next: next)
                    .padding(.vertical)
            } else if inSplitView {
                // The board is in the board column: the counts, with what each means, and
                // what to do.
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        StudyCountsList(counts: model.counts, highlight: model.askedKind)
                        VStack(alignment: .leading, spacing: 8) {
                            openingName
                            status
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 12) {
                    // Edge to edge on a phone, as in the builder.
                    DrillBoard(model: model)
                        .frame(maxWidth: 680)
                    // Laid out like the builder: move list, then opening name; then what to do,
                    // with the counts (status, not a control, so not in a bar).
                    VStack(alignment: .leading, spacing: 8) {
                        LineHistory(tree: model.document.tree, nodes: model.playedNodes)
                        openingName
                        HStack(alignment: .firstTextBaseline) {
                            status
                            Spacer()
                            StudyCountsView(counts: model.counts, highlight: model.askedKind)
                                .font(.headline.monospacedDigit())
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal)
                    Spacer(minLength: 0)
                }
                // The board under the bar, as in the builder.
                .padding(.bottom)
            }
        }
        .boardScreenTitle(model.mode.title, repertoire: model.document.name, inSplitView: inSplitView)
        .toolbar {
            if !model.finished {
                // In the split view the actions are in the panel's bar, as in the builder.
                let split = inSplitView
                let actions: ToolbarItemPlacement = split ? .trailingBar : .bottomActions
                ToolbarItem(placement: actions) {
                    Button("Hint", systemImage: "lightbulb") { model.hint() }
                        .disabled(!model.canMove)
                }
                if !split {
                    ToolbarSpacer(.flexible, placement: .bottomActions)
                }
                // Both leave the board to look the move up, so both count as Again. In the split
                // view Analysis is in the board column's bar.
                ToolbarItemGroup(placement: actions) {
                    Button("Browse Repertoire", systemImage: "list.bullet.indent") {
                        if let node = model.browseNode() { browse(node) }
                    }
                    if !split {
                        Button("Analysis", systemImage: "cpu") {
                            analysis = AnalysisModel(document: model.document, moves: model.analysisMoves(),
                                                     orientation: model.color, origin: .study)
                        }
                    }
                }
            }
        }
        .navigationDestination(item: $browsing) { request in
            BuilderScreen(document: model.document, start: request.node)
        }
        .sensoryFeedback(trigger: model.feedback) { _, new in
            switch new {
            case .correct: .success
            case .wrong: .error
            default: nil
            }
        }
    }

    /// Browses from `node`: through the library, which keeps only this screen under it, else
    /// pushed here.
    private func browse(_ node: NodeID) {
        if let openScreen {
            openScreen(.browse(model.document.entryID, node))
        } else {
            browsing = BrowseRequest(node: node)
        }
    }

    @ViewBuilder
    private var openingName: some View {
        if let name = model.openingName {
            Text(name).font(.subheadline.weight(.semibold)).lineLimit(2)
        }
    }

    /// What to do now, or how the last move went.
    private var status: some View {
        Group {
            switch model.feedback {
            case .correct:
                Label("Correct", systemImage: "checkmark.circle.fill").foregroundStyle(.done)
            case .wrong(let expected):
                Label("Not quite, play \(expected.san)", systemImage: "xmark.circle.fill").foregroundStyle(.wrong)
            case .alternative:
                Label("That's your alternative. Play your main move.", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.attention)
            case .newMove(let move):
                Label("New move: play \(move.san)", systemImage: "sparkles").foregroundStyle(.new)
            case .none:
                if model.isUserTurn {
                    Label("Your move", systemImage: "circle.fill")
                } else {
                    Label("Playing the line…", systemImage: "circle.dotted").foregroundStyle(.secondary)
                }
            }
        }
        .font(.headline)
        .animation(.default, value: model.feedback)
    }
}

/// A study session that owns its model: opened outside the library (Study Branch from a
/// builder in the Statistics tab).
struct DrillScreen: View {
    @State private var model: DrillModel

    init(document: RepertoireDocument, mode: DrillMode) {
        _model = State(initialValue: DrillModel(document: document, mode: mode))
    }

    var body: some View {
        DrillView(model: model)
    }
}

/// The study board: moves played on it answer the card.
struct DrillBoard: View {
    let model: DrillModel

    var body: some View {
        BoardView(position: model.position, orientation: model.color, lastMove: model.lastMove,
                  arrows: model.arrows, badge: model.badge, movableSide: model.canMove ? model.color : nil) { from, to, promotion in
            model.userMoved(from: from, to: to, promotion: promotion)
        }
    }
}

/// The study board in the split view's board column, whose bars have Lichess and, at the
/// bottom, the moves played (as Browse's).
struct DrillBoardColumn: View {
    let model: DrillModel

    var body: some View {
        BoardColumnLayout {
            DrillBoard(model: model)
        } below: {
            EmptyView()
        }
    }
}

/// The moves played so far on a study line. Read-only: going to a move would show its answer.
struct LineHistory: View {
    let tree: RepertoireDocument.Tree
    let nodes: [NodeID]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // Plies from the line's position: after a transposition a node's own ply can differ.
                    ForEach(Array(nodes.enumerated()), id: \.element) { i, id in
                        if let move = tree[id]?.move {
                            MoveChip(ply: Int(tree.root.ply) + i + 1, san: move.san, isCurrent: i == nodes.count - 1)
                                .id(id)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, 8, for: .scrollContent)
            .onChange(of: nodes.last) { if let last = nodes.last { proxy.scrollTo(last, anchor: .trailing) } }
        }
    }
}

/// Anki's three counts, colored like the studied bar: New, Learning (gray), To Review (app color).
struct StudyCountsView: View {
    let counts: Counts
    var highlight: QueueKind?

    var body: some View {
        HStack(spacing: 10) {
            number(counts.new, .unstudied, .new)
            number(counts.learning, .learning, .learning)
            number(counts.review, .progress, .review)
        }
        // Next to the status the numbers never truncate; the status wraps instead.
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(counts.new) new, \(counts.learning) learning, \(counts.review) to review")
    }

    private func number(_ value: Int64, _ color: ThemeColor, _ kind: QueueKind) -> some View {
        Text(value.formatted())
            .foregroundStyle(color)
            .underline(highlight == kind)
    }
}

/// Anki's three counts one per line with what each means, where there is room (split view).
struct StudyCountsList: View {
    let counts: Counts
    var highlight: QueueKind?

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            row(counts.new, .unstudied, .new, "New", "Moves you haven't studied yet")
            row(counts.learning, .learning, .learning, "Learning", "Moves you're learning, shown again within minutes")
            row(counts.review, .progress, .review, "To Review", "Learned moves due today")
        }
    }

    private func row(_ value: Int64, _ color: ThemeColor, _ kind: QueueKind, _ title: String, _ detail: String) -> some View {
        GridRow {
            Text(value.formatted())
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .underline(highlight == kind)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
