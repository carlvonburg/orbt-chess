import OpeningCore
import SwiftUI

enum DrillMode: Hashable, CustomStringConvertible {
    /// Today's cards (Anki's "Study Now").
    case study
    /// Every card under a position (Anki's custom study, a filtered deck).
    case branch(NodeID)

    var description: String {
        switch self {
        case .study: "study"
        case .branch(let id): "branch\(id)"
        }
    }

    var title: String {
        switch self {
        case .study: "Study"
        case .branch: "Study Branch"
        }
    }
}

/// Plays study lines one after another. Each card on a line is answered like an Anki card:
/// a wrong move, a hint or browsing is Again; a correct move is Good.
@Observable
final class DrillModel {
    enum Feedback: Equatable {
        case none
        case correct
        case wrong(expected: PlayedMove)
        case alternative
        case newMove(PlayedMove)
    }

    let document: RepertoireDocument
    let mode: DrillMode
    /// New moves to add to today's limit before studying (Anki's custom study).
    let learnMore: Int
    private(set) var session: StudySession?
    private(set) var line: StudyLine?
    private(set) var run: LineRun?
    private(set) var feedback: Feedback = .none
    private(set) var finished = false
    private(set) var showHint = false
    /// Cards answered in this session.
    private(set) var answeredCount = 0

    /// Observed: `isUserTurn` depends on it, so the board unlocks when autoplay ends.
    private var autoplay: Task<Void, Never>?
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var turnStarted = Date.now
    /// Cards already answered on the current line (a wrong try answers once).
    @ObservationIgnored private var answeredOnLine: Set<EPD> = []

    init(document: RepertoireDocument, mode: DrillMode, learnMore: Int = 0) {
        self.document = document
        self.mode = mode
        self.learnMore = learnMore
    }

    var color: Side { document.color }
    var isFiltered: Bool { if case .branch = mode { true } else { false } }
    var counts: CardQueues.Counts { session?.queue.counts ?? CardQueues.Counts() }
    var nextLearningDue: Date? { session?.queue.nextLearningDue }

    var position: ChessPosition {
        guard let run, let node = document.tree[run.currentNode] else { return .start }
        return node.position
    }
    var lastMove: PlayedMove? { run.flatMap { document.tree[$0.currentNode]?.move } }
    /// The moves on the board, from the start of the line.
    var playedNodes: ArraySlice<NodeID> { run.map { $0.nodes[...$0.index].dropFirst() } ?? [] }
    var openingName: String? { run.flatMap { document.openingName(at: $0.currentNode) } }

    private var currentRole: MoveRole? {
        guard let run, run.isOwnTurn else { return nil }
        return line?.roles[run.index]
    }

    private var currentEPD: EPD? { run.flatMap { document.tree[$0.currentNode]?.epd } }

    var isUserTurn: Bool {
        guard autoplay == nil, let role = currentRole else { return false }
        return role != .auto
    }

    /// The kind of card being asked, for highlighting its count.
    var askedKind: CardQueues.Kind? {
        guard isUserTurn, let epd = currentEPD else { return nil }
        return session?.queue.kind(of: epd)
    }

    var arrows: [BoardArrow] {
        switch feedback {
        case .wrong(let expected), .newMove(let expected):
            return [BoardArrow(from: expected.from, to: expected.to, style: .hint, width: 0.2)]
        default:
            if showHint, let expected = run?.expected {
                return [BoardArrow(from: expected.from, to: expected.to, style: .hint, width: 0.2, opacity: 0.6)]
            }
            return []
        }
    }

    func start() {
        // Runs again when the view reappears (after browsing, or as it's pushed): resume the
        // opponent's moves if they were stopped, keep the session.
        if session != nil {
            if interrupted { interrupted = false; continueLine() }
            return
        }
        if learnMore > 0 { document.extendNewLimitToday(by: learnMore) }
        session = document.studySession(branch: { if case .branch(let id) = mode { id } else { nil } }())
        nextLine()
    }

    func stop() {
        interrupted = autoplay != nil
        autoplay?.cancel()
        autoplay = nil
    }

    func userMoved(from: BoardSquare, to: BoardSquare, promotion: PieceKind?) {
        guard isUserTurn, var run, let epd = currentEPD, let role = currentRole,
              let (move, _) = position.play(from: from, to: to, promotion: promotion) else { return }
        let outcome = run.userPlayed(uci: move.uci)
        self.run = run
        switch outcome {
        case .correct:
            if case .answer(let kind) = role, !answeredOnLine.contains(epd) {
                answer(epd, kind: kind, rating: .good)
            }
            session?.didPlay(epd)
            showHint = false
            feedback = .correct
            continueLine()
        case .alternative:
            feedback = .alternative
        case .wrong(let expected):
            if case .answer(let kind) = role, !answeredOnLine.contains(epd) {
                answer(epd, kind: kind, rating: .again)
            }
            feedback = .wrong(expected: expected)
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                if case .wrong = feedback {
                    // Anki shows the answer: keep the arrow until the move is played
                    feedback = .none
                    showHint = true
                }
            }
        }
    }

    /// The node to open when the user browses the repertoire mid-line. Browsing on your
    /// own turn reveals the answer, so it counts as Again.
    func browseNode() -> NodeID? {
        guard let run else { return nil }
        failCurrentCard()
        return run.currentNode
    }

    func hint() {
        failCurrentCard()
        showHint = true
    }

    /// The moves to the board, for Lichess analysis. Looking counts as Again, like browsing.
    func analysisMoves() -> [PlayedMove] {
        failCurrentCard()
        guard let run else { return [] }
        return document.tree.moves(to: run.currentNode)
    }

    /// Anki's custom study "Increase today's new card limit".
    func increaseNewLimit(by count: Int) {
        let timing = SchedTiming()
        document.extendNewLimitToday(by: count, timing: timing)
        session?.rebuild(cards: document.sidecar.studyCards, limits: document.remainingLimits(timing), timing: timing,
                         learnAheadSecs: document.deckConfig.learnAheadSecs)
        finished = false
        nextLine()
    }

    /// Looks for cards again (learning cards that became due).
    func checkAgain() {
        finished = false
        nextLine()
    }

    // MARK: Private

    private func failCurrentCard() {
        guard isUserTurn, let epd = currentEPD, case .answer(let kind) = currentRole, !answeredOnLine.contains(epd) else { return }
        answer(epd, kind: kind, rating: .again)
    }

    private func answer(_ epd: EPD, kind: AnswerKind, rating: Rating) {
        guard var session else { return }
        let timing = SchedTiming()
        let taken = Int(Date.now.timeIntervalSince(turnStarted) * 1000)
        let card = document.answer(epd, position: session.position(of: epd), rating: rating,
                                   filtered: isFiltered || kind == .reviewAhead, takenMillis: taken, timing: timing)
        session.didAnswer(epd, card: card, timing: timing)
        self.session = session
        answeredOnLine.insert(epd)
        answeredCount += 1
    }

    private func continueLine() {
        autoplay?.cancel()
        autoplay = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(450))
            while var run = self.run, !run.isFinished, !run.isOwnTurn || self.currentRole == .auto {
                guard !Task.isCancelled else { return }
                run.advance()
                self.run = run
                try? await Task.sleep(for: .milliseconds(450))
            }
            guard !Task.isCancelled else { return }
            self.autoplay = nil
            guard let run = self.run else { return }
            if run.isFinished {
                try? await Task.sleep(for: .milliseconds(400))
                self.nextLine()
            } else {
                self.prepareUserTurn()
            }
        }
    }

    /// A New card is shown first (its answer), then the user plays it.
    private func prepareUserTurn() {
        turnStarted = .now
        showHint = false
        if currentRole == .answer(.introduce), let expected = run?.expected {
            feedback = .newMove(expected)
        } else if feedback != .correct {
            feedback = .none
        }
    }

    private func nextLine() {
        autoplay?.cancel()
        autoplay = nil
        guard var session else { return }
        session.updateLearningCutoff(now: Int64(Date.now.timeIntervalSince1970))
        let next = session.nextLine(cards: document.sidecar.studyCards)
        self.session = session
        guard let next else {
            line = nil
            run = nil
            finished = true
            feedback = .none
            return
        }
        let previous = run
        line = next
        answeredOnLine = []
        feedback = .none
        showHint = false
        // Take moves back to where the lines part when that's shorter than replaying from move 1.
        guard var previous, let start = next.resumeIndex(from: previous.nodes, shown: previous.index) else {
            run = LineRun(trainer: document.trainer, nodes: next.nodes)
            continueLine()
            return
        }
        autoplay = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(300))
            while previous.index > start {
                guard !Task.isCancelled else { return }
                previous.takeBack()
                self.run = previous
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            self.run = LineRun(trainer: self.document.trainer, nodes: next.nodes, index: start)
            self.continueLine()
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
        .sheet(item: $analysis) { request in
            SafariView(url: request.url).ignoresSafeArea()
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            if model.finished {
                finishedView.padding()
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

    private var finishedView: some View {
        ContentUnavailableView {
            Label(model.answeredCount > 0 ? "Congratulations!" : "Nothing to study", systemImage: "checkmark.seal.fill")
        } description: {
            VStack(spacing: 8) {
                Text(model.answeredCount > 0
                     ? "You have finished \(model.document.name) for now."
                     : model.isFiltered ? "There are no moves in this branch yet." : "No moves are due right now.")
                if let due = model.nextLearningDue {
                    Text("More moves you are learning are due at \(due.formatted(date: .omitted, time: .shortened)).")
                }
            }
        } actions: {
            VStack(spacing: 12) {
                if model.nextLearningDue != nil {
                    Button("Check Again") { model.checkAgain() }
                        .buttonStyle(.glass)
                }
                if !model.isFiltered {
                    Menu("Study More New Moves") {
                        ForEach([5, 10, 20], id: \.self) { n in
                            Button("Increase Today's Limit by \(n)") { model.increaseNewLimit(by: n) }
                        }
                    }
                    .buttonStyle(.glass)
                }
                if let next {
                    Button("Continue with \(next.name)") { next.start() }
                        .buttonStyle(.glassProminent)
                    Button("Done") { dismiss() }
                        .buttonStyle(.glass)
                } else {
                    Button("Done") { dismiss() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }
}

/// The moves played so far on a study line. Read-only: going to a move would show its answer.
private struct LineHistory: View {
    let tree: RepertoireTree
    let nodes: ArraySlice<NodeID>

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // Plies from the line's position: after a transposition a node's own ply can differ.
                    ForEach(Array(nodes.enumerated()), id: \.element) { i, id in
                        if let move = tree[id]?.move {
                            MoveChip(ply: tree.root.ply + i + 1, san: move.san, isCurrent: i == nodes.count - 1)
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
    let counts: CardQueues.Counts
    var highlight: CardQueues.Kind?

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

    private func number(_ value: Int, _ color: Color, _ kind: CardQueues.Kind) -> some View {
        Text(value.formatted())
            .foregroundStyle(color)
            .underline(highlight == kind)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
