import Foundation
import Observation
import OpeningCoreRust

/// Navigation state of the builder: the current node plus a draft of moves played on the
/// board that are not saved yet. The Rust core (`BuilderSession`) holds the state and the
/// rules; this forwards to it and hands what each action changed to the document.
@Observable
final class BuilderModel {
    let document: RepertoireDocument
    @ObservationIgnored private let session: BuilderSession
    /// Bumped after every action, so views re-read the session.
    private var stamp = 0

    init(document: RepertoireDocument, start: NodeID? = nil) {
        self.document = document
        session = BuilderSession(doc: document.core, start: start)
    }

    /// Reading this registers a view for the session's and the document's changes.
    private func observe() {
        _ = stamp
        _ = document.revision
    }

    private func act(_ changes: Changes) {
        document.apply(changes)
        stamp += 1
    }

    var tree: RepertoireDocument.Tree { document.tree }

    var current: NodeID { observe(); return session.current() }
    var node: Node? { tree[current] }

    var orientation: Side {
        get { observe(); return session.orientation() }
        set { session.setOrientation(side: newValue); stamp += 1 }
    }

    /// Moves played past `current` that are not in the repertoire yet.
    var draft: [PlayedMove] { observe(); return session.draft() }
    var hasDraft: Bool { observe(); return session.hasDraft() }

    /// Position on the board (after the draft).
    var position: ChessPosition { observe(); return session.position() }

    /// When the current position's lines are stored at another node (a transposition), that node.
    var continuation: NodeID? { observe(); return session.continuation() }

    /// While a draft is on the board: a saved node with the same position whose lines continue
    /// from it, i.e. the draft transposes into your repertoire.
    var draftTransposition: NodeID? { observe(); return session.draftTransposition() }

    /// The saved node with lines that `uci`, played on the board, leads into by another move
    /// order. Nil when the move is your saved line itself, or reaches nothing you have.
    func transposition(after uci: String) -> NodeID? { observe(); return session.transpositionAfter(uci: uci) }

    /// The node whose moves the panels show: the current one, or where its lines continue.
    var shownNode: Node? { observe(); return tree[session.shownNode()] }

    /// Not at the start position with nothing played on the board.
    var canBack: Bool { current != RepertoireTree.rootID || hasDraft }
    var canForward: Bool { observe(); return session.canForward() }
    /// The main line ahead, as forward plays it (the move strip shows it after the current move).
    var lineAhead: [NodeID] { observe(); return session.lineAhead(limit: 40) }
    var lastMove: PlayedMove? { observe(); return session.lastMove() }
    var isUserTurnOnBoard: Bool { observe(); return session.isUserTurnOnBoard() }

    /// Probability of reaching the board position. Nil while a needed statistic is missing.
    var reachOnBoard: Double? { observe(); return session.reachOnBoard() }

    /// Opponent replies at the board position while a draft is on it.
    var draftReplies: [ReplyInfo]? { observe(); return session.draftReplies() }

    /// Moves from the start to the board position, including the draft.
    var movesToBoard: [PlayedMove] { observe(); return session.movesToBoard() }

    /// Arrows for the current node: your saved moves, or the opponent's replies sized by
    /// frequency with missing required replies as dashed orange arrows.
    var arrows: [BoardArrow] { observe(); return session.arrows().map(BoardArrow.init) }

    // MARK: Navigation

    func go(to id: NodeID) { act(session.go(id: id)) }
    func back() { act(session.back()) }
    func forward() { act(session.forward()) }

    /// Switch to the previous/next sibling line (↑/↓ keys).
    func sibling(_ offset: Int) { act(session.sibling(offset: Int64(offset))) }

    /// A move made on the board: follows the repertoire if the move exists there,
    /// otherwise extends the draft.
    func play(from: BoardSquare, to: BoardSquare, promotion: PieceKind?) {
        act(session.play(from: from, to: to, promotion: promotion))
    }

    func play(uci: String) { act(session.playUci(uci: uci)) }

    /// Previews a reply or candidate from the panel as a draft move.
    func preview(uci: String) { act(session.preview(uci: uci)) }

    // MARK: Editing

    func saveDraft() { act(session.saveDraft()) }

    func discardDraft() {
        session.discardDraft()
        stamp += 1
    }

    /// A line from the analysis board: its saved moves are followed, the rest is the draft.
    func setLine(_ moves: [PlayedMove]) { act(session.setLine(moves: moves.map(\.uci))) }

    func delete(_ id: NodeID) { act(session.delete(id: id)) }

    /// Undoes the last edit; the board stays on a saved position.
    func undo() { act(session.undo()) }

    /// Goes to the biggest gap below the current node, or in the whole repertoire.
    func goToBiggestGap() { act(session.goToBiggestGap()) }

    func go(to gap: CoverageGap) { act(session.goToGap(gap: gap)) }
}
