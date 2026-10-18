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
    private(set) var session: StudySession?
    private(set) var line: StudyLine?
    private(set) var run: LineRun?
    private(set) var feedback: Feedback = .none
    private(set) var finished = false
    private(set) var showHint = false
    private(set) var note: String?
    /// Cards answered in this session.
    private(set) var answeredCount = 0

    @ObservationIgnored private var autoplay: Task<Void, Never>?
    @ObservationIgnored private var turnStarted = Date.now
    /// Cards already answered on the current line (a wrong try answers once).
    @ObservationIgnored private var answeredOnLine: Set<EPD> = []

    init(document: RepertoireDocument, mode: DrillMode) {
        self.document = document
        self.mode = mode
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
        session = document.studySession(branch: { if case .branch(let id) = mode { id } else { nil } }())
        nextLine()
    }

    func stop() {
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
            note = document.tree[run.currentNode]?.note.nilIfEmpty
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

    func skipLine() {
        nextLine()
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
                if let text = self.document.tree[run.currentNode]?.note.nilIfEmpty { self.note = text }
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
        line = next
        run = LineRun(trainer: document.trainer, nodes: next.nodes)
        answeredOnLine = []
        feedback = .none
        showHint = false
        note = nil
        continueLine()
    }
}

struct DrillView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: DrillModel
    @State private var browsing: BrowseRequest?

    private struct BrowseRequest: Identifiable {
        let node: NodeID
        var id: NodeID { node }
    }

    init(document: RepertoireDocument, mode: DrillMode) {
        _model = State(initialValue: DrillModel(document: document, mode: mode))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if model.finished {
                    finishedView
                } else {
                    status
                    BoardView(position: model.position, orientation: model.color, lastMove: model.lastMove,
                              arrows: model.arrows, movableSide: model.isUserTurn ? model.color : nil) { from, to, promotion in
                        model.userMoved(from: from, to: to, promotion: promotion)
                    }
                    .clipShape(.rect(cornerRadius: 6))
                    .frame(maxWidth: 640)
                    if let note = model.note {
                        Text(note)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.yellow.opacity(0.15), in: .rect(cornerRadius: 8))
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding()
            .navigationTitle(model.mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        model.stop()
                        dismiss()
                    }
                }
                if !model.finished {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Hint", systemImage: "lightbulb") { model.hint() }
                            .disabled(!model.isUserTurn)
                        Button("Browse Repertoire", systemImage: "list.bullet.indent") {
                            if let node = model.browseNode() { browsing = BrowseRequest(node: node) }
                        }
                        Spacer()
                        Button("Skip Line", systemImage: "forward") { model.skipLine() }
                    }
                }
            }
            .sensoryFeedback(trigger: model.feedback) { _, new in
                switch new {
                case .correct: .success
                case .wrong: .error
                default: nil
                }
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
        .sheet(item: $browsing) { request in
            NavigationStack {
                BuilderView(document: model.document, start: request.node)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Back to Training", systemImage: "xmark") { browsing = nil }
                        }
                    }
            }
        }
    }

    private var status: some View {
        HStack {
            Group {
                switch model.feedback {
                case .correct:
                    Label("Correct", systemImage: "checkmark.circle.fill").glassChip(tint: .green)
                case .wrong(let expected):
                    Label("Not quite — \(expected.san)", systemImage: "xmark.circle.fill").glassChip(tint: .red)
                case .alternative:
                    Label("That's your alternative. Play your main move.", systemImage: "arrow.triangle.branch").glassChip(tint: .yellow)
                case .newMove(let move):
                    Label("New move: play \(move.san)", systemImage: "sparkles").glassChip(tint: .blue)
                case .none:
                    Label(model.isUserTurn ? "Your move" : "Opponent is moving…", systemImage: "circle.fill")
                        .glassChip()
                }
            }
            .font(.subheadline.weight(.semibold))
            .animation(.default, value: model.feedback)
            Spacer()
            StudyCountsView(counts: model.counts, highlight: model.askedKind)
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
    }

    private var finishedView: some View {
        ContentUnavailableView {
            Label(model.answeredCount > 0 ? "Congratulations!" : "Nothing to study", systemImage: "checkmark.seal.fill")
        } description: {
            VStack(spacing: 8) {
                Text(model.answeredCount > 0
                     ? "You have finished this repertoire for now."
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
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
            }
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
