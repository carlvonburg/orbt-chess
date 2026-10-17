import OpeningCore
import SwiftUI

enum DrillMode: Hashable, CustomStringConvertible {
    case due
    case learnNew
    case branch(NodeID)

    var description: String {
        switch self {
        case .due: "due"
        case .learnNew: "new"
        case .branch(let id): "branch\(id)"
        }
    }

    var title: String {
        switch self {
        case .due: "Review"
        case .learnNew: "Learn New Moves"
        case .branch: "Train Branch"
        }
    }
}

/// Runs drill lines one after another and records the results.
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
    private(set) var session: DrillSession?
    private(set) var feedback: Feedback = .none
    private(set) var linesDone = 0
    private(set) var finished = false
    private(set) var showHint = false
    private(set) var note: String?

    @ObservationIgnored private var done: Set<EPD> = []
    @ObservationIgnored private var branchLines: [Trainer.Line] = []
    @ObservationIgnored private var newIntroduced = 0
    @ObservationIgnored private var autoplay: Task<Void, Never>?
    static let newPerSession = 10

    init(document: RepertoireDocument, mode: DrillMode) {
        self.document = document
        self.mode = mode
        if case .branch(let root) = mode {
            branchLines = document.trainer.allLines(under: root).shuffled()
        }
    }

    var totalLines: Int? {
        if case .branch = mode { return linesDone + branchLines.count + (session == nil ? 0 : 1) }
        return nil
    }

    var color: Side { document.color }
    var position: ChessPosition {
        guard let session, let node = document.tree[session.currentNode] else { return .start }
        return node.position
    }
    var lastMove: PlayedMove? { session.flatMap { document.tree[$0.currentNode]?.move } }
    var isUserTurn: Bool { session?.isUserTurn == true && autoplay == nil }

    var arrows: [BoardArrow] {
        switch feedback {
        case .wrong(let expected), .newMove(let expected):
            return [BoardArrow(from: expected.from, to: expected.to, style: .hint, width: 0.2)]
        default:
            if showHint, let expected = session?.expected {
                return [BoardArrow(from: expected.from, to: expected.to, style: .hint, width: 0.2, opacity: 0.6)]
            }
            return []
        }
    }

    func start() {
        nextLine()
    }

    func stop() {
        autoplay?.cancel()
        recordCurrent()
    }

    func userMoved(from: BoardSquare, to: BoardSquare, promotion: PieceKind?) {
        guard var session, session.isUserTurn,
              let (move, _) = position.play(from: from, to: to, promotion: promotion) else { return }
        let outcome = session.userPlayed(uci: move.uci)
        self.session = session
        showHint = false
        switch outcome {
        case .correct:
            feedback = .correct
            note = document.tree[session.currentNode]?.note.nilIfEmpty
            continueLine()
        case .alternative:
            feedback = .alternative
        case .wrong(let expected):
            feedback = .wrong(expected: expected)
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                if case .wrong = feedback {
                    feedback = .none
                    prepareUserTurn()
                }
            }
        }
    }

    func hint() {
        session?.useHint()
        showHint = true
    }

    func skipLine() {
        recordCurrent()
        nextLine()
    }

    // MARK: Private

    private func continueLine() {
        autoplay?.cancel()
        autoplay = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(450))
            while var session = self.session, !session.isFinished, !session.isUserTurn {
                guard !Task.isCancelled else { return }
                _ = session.playOpponent()
                self.session = session
                if let text = self.document.tree[session.currentNode]?.note.nilIfEmpty { self.note = text }
                try? await Task.sleep(for: .milliseconds(450))
            }
            self.autoplay = nil
            guard let session = self.session else { return }
            if session.isFinished {
                try? await Task.sleep(for: .milliseconds(400))
                self.recordCurrent()
                self.nextLine()
            } else {
                self.prepareUserTurn()
            }
        }
    }

    /// In "learn new" mode a card the user has not seen is demonstrated first.
    private func prepareUserTurn() {
        guard let session, let expected = session.expected, let epd = document.tree[session.currentNode]?.epd else { return }
        if document.sidecar.cards[epd] == nil, mode != .due {
            feedback = .newMove(expected)
        } else if feedback != .correct {
            feedback = .none
        }
    }

    private func recordCurrent() {
        guard let session else { return }
        let grades = session.grades()
        document.record(grades)
        done.formUnion(grades.keys)
        if session.isFinished { linesDone += 1 }
        self.session = nil
    }

    private func nextLine() {
        let trainer = document.trainer
        let reach: (NodeID) -> Double = { [document] id in document.coverage[id]?.reach ?? 0 }
        var line: Trainer.Line?
        switch mode {
        case .due:
            line = trainer.nextDueLine(cards: document.sidecar.cards, excluding: done, weight: reach)
        case .learnNew:
            if newIntroduced < Self.newPerSession {
                line = trainer.nextNewLine(cards: document.sidecar.cards, excluding: done, weight: reach)
                newIntroduced += 1
            }
        case .branch:
            line = branchLines.isEmpty ? nil : branchLines.removeFirst()
        }
        guard let line, line.nodes.count > 1 else {
            finished = true
            feedback = .none
            return
        }
        session = DrillSession(trainer: trainer, line: line)
        feedback = .none
        note = nil
        if session!.isUserTurn { prepareUserTurn() } else { continueLine() }
    }
}

struct DrillView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: DrillModel

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
            if let total = model.totalLines {
                Text("\(model.linesDone)/\(total) lines").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("\(model.linesDone) lines").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var finishedView: some View {
        ContentUnavailableView {
            Label(model.linesDone > 0 ? "Session complete" : "Nothing to train", systemImage: "checkmark.seal.fill")
        } description: {
            Text(model.linesDone > 0
                 ? "You played \(model.linesDone) line\(model.linesDone == 1 ? "" : "s")."
                 : model.mode == .due ? "No moves are due right now." : "There are no lines here yet.")
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(.glassProminent)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
