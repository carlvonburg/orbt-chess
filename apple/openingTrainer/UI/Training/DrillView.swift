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

    var position: ChessPosition { observe(); return session.position() }
    var lastMove: PlayedMove? { observe(); return session.lastMove() }
    /// The moves on the board, from the start of the line.
    var playedNodes: [NodeID] { observe(); return session.playedNodes() }
    var openingName: String? {
        observe()
        return session.currentNode().flatMap { document.openingName(at: $0) }
    }
    var isUserTurn: Bool { observe(); return session.isUserTurn() }

    /// The kind of card being asked, for highlighting its count.
    var askedKind: QueueKind? { observe(); return session.askedKind() }

    var arrows: [BoardArrow] { observe(); return session.arrows().map(BoardArrow.init) }

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
        changed()
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

    /// The moves to the board, for Lichess analysis. Looking counts as Again, like browsing.
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
    private func changed() {
        stamp += 1
        timer?.cancel()
        timer = nil
        let delay: Int
        switch session.phase() {
        case .rewinding: delay = 250
        case .autoplay: delay = 450
        case .lineDone: delay = 400
        case .idle, .userTurn, .finished: return
        }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
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
    @Environment(\.dismiss) private var dismiss
    @State private var model: DrillModel
    @State private var browsing: BrowseRequest?

    private struct BrowseRequest: Hashable {
        let node: NodeID
    }

    @State private var analysis: AnalysisRequest?

    private struct AnalysisRequest: Identifiable {
        let url: URL
        var id: URL { url }
    }

    /// The next repertoire when studying all of them: its name and how to go on.
    private let next: (name: String, start: () -> Void)?
    /// Pushed onto the caller's navigation stack (Study Now) instead of presented full screen.
    private let pushed: Bool

    init(document: RepertoireDocument, mode: DrillMode, pushed: Bool = false, learnMore: Int = 0,
         next: (name: String, start: () -> Void)? = nil) {
        _model = State(initialValue: DrillModel(document: document, mode: mode, learnMore: learnMore))
        self.pushed = pushed
        self.next = next
    }

    var body: some View {
        Group {
            if pushed {
                content.toolbarVisibility(.hidden, for: .tabBar)
            } else {
                NavigationStack { content }
            }
        }
        .task { model.start() }
        // Browsing pushes the builder on top; training goes on when it's popped.
        .onDisappear { if browsing == nil { model.stop() } }
        .checksCoverage(model.document)
        .sheet(item: $analysis) { request in
            SafariView(url: request.url).ignoresSafeArea()
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            if model.finished {
                StudyFinishedView(model: model, next: next)
            } else {
                // Edge to edge on a phone, as in the builder.
                BoardView(position: model.position, orientation: model.color, lastMove: model.lastMove,
                          arrows: model.arrows, movableSide: model.isUserTurn ? model.color : nil) { from, to, promotion in
                    model.userMoved(from: from, to: to, promotion: promotion)
                }
                .frame(maxWidth: 680)
                // Laid out like the builder: move list, then opening name; then what to do.
                VStack(alignment: .leading, spacing: 8) {
                    LineHistory(tree: model.document.tree, nodes: model.playedNodes)
                    if let name = model.openingName {
                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    }
                    status
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical)
        .navigationTitle(model.mode.title)
        .navigationSubtitle(model.document.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.finished {
                ToolbarItem(placement: .topBarTrailing) {
                    StudyCountsView(counts: model.counts, highlight: model.askedKind)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                .sharedBackgroundVisibility(.hidden)
            }
            if !pushed {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        model.stop()
                        dismiss()
                    }
                }
            }
            if !model.finished {
                ToolbarItem(placement: .bottomBar) {
                    Button("Hint", systemImage: "lightbulb") { model.hint() }
                        .disabled(!model.isUserTurn)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                // Both leave the board to look the move up, so both count as Again.
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Browse Repertoire", systemImage: "list.bullet.indent") {
                        if let node = model.browseNode() { browsing = BrowseRequest(node: node) }
                    }
                    Button("Analyze on Lichess", systemImage: "cpu") {
                        analysis = AnalysisRequest(url: LichessLinks.analysis(moves: model.analysisMoves(),
                                                                              orientation: model.color))
                    }
                }
            }
        }
        .navigationDestination(item: $browsing) { request in
            BuilderView(document: model.document, start: request.node)
        }
        .sensoryFeedback(trigger: model.feedback) { _, new in
            switch new {
            case .correct: .success
            case .wrong: .error
            default: nil
            }
        }
    }

    /// What to do now, or how the last move went.
    private var status: some View {
        Group {
            switch model.feedback {
            case .correct:
                Label("Correct", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .wrong(let expected):
                Label("Not quite, play \(expected.san)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            case .alternative:
                Label("That's your alternative. Play your main move.", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
            case .newMove(let move):
                Label("New move: play \(move.san)", systemImage: "sparkles").foregroundStyle(.blue)
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

/// The moves played so far on a study line. Read-only: going to a move would show its answer.
private struct LineHistory: View {
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
            .onChange(of: nodes.last) { if let last = nodes.last { proxy.scrollTo(last, anchor: .trailing) } }
        }
    }
}

/// Anki's three counts: New (blue), Learning (red), To Review (green).
struct StudyCountsView: View {
    let counts: Counts
    var highlight: QueueKind?

    var body: some View {
        HStack(spacing: 10) {
            number(counts.new, .blue, .new)
            number(counts.learning, .red, .learning)
            number(counts.review, .green, .review)
        }
        // The toolbar would truncate the numbers; let the title truncate instead.
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(counts.new) new, \(counts.learning) learning, \(counts.review) to review")
    }

    private func number(_ value: Int64, _ color: Color, _ kind: QueueKind) -> some View {
        Text(value.formatted())
            .foregroundStyle(color)
            .underline(highlight == kind)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
