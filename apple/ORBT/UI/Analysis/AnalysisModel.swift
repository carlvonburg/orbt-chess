import Foundation
import Observation
import OpeningCoreRust

/// The analysis board: the line from Browse or Study, and the variations played on it. The
/// Rust core (`AnalysisSession`) holds the tree; nothing is saved. A screen pushed on Browse or
/// Study: going back to Browse puts the line to the selected move on the builder as an unsaved
/// draft; going back to Study drops it.
@Observable
final class AnalysisModel: Identifiable, Hashable {
    enum Origin {
        case build(BuilderModel)
        case study
    }

    let id = UUID()
    let document: RepertoireDocument
    let origin: Origin
    /// The engine's lines and arrows (the cloud eval and Stockfish).
    var engineOn = true
    /// What the screen presents. In the split view the board column's menu sets it and the
    /// panel presents it.
    var showsSettings = false
    var page: WebPage?
    @ObservationIgnored private let session: AnalysisSession
    @ObservationIgnored private var finished = false
    /// Bumped after every action, so views re-read the session.
    private var stamp = 0

    init(document: RepertoireDocument, moves: [PlayedMove], orientation: Side, origin: Origin) {
        self.document = document
        self.origin = origin
        let startFen = document.tree.position(of: RepertoireTree.rootID)?.fen()
        session = AnalysisSession(startFen: startFen, moves: moves.map(\.uci), orientation: orientation)
    }

    static func == (lhs: AnalysisModel, rhs: AnalysisModel) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    private func act(_ changed: Bool = true) {
        if changed { stamp += 1 }
    }

    private func observe() { _ = stamp }

    var startFen: String { session.startFen() }
    var current: UInt32 { observe(); return session.current() }
    var position: ChessPosition { observe(); return session.position() }
    var lastMove: PlayedMove? { observe(); return session.lastMove() }
    var movesToBoard: [PlayedMove] { observe(); return session.movesToBoard() }
    /// The move list: the main line cut where variations branch off, variations indented.
    var moveList: [MoveListRow] { observe(); return session.moveList() }
    /// The moves ahead on the line forward follows (each move's first child).
    var lineAhead: [PlayedMove] { observe(); return session.lineAhead() }
    var canBack: Bool { current != 0 }

    /// The ply before the first move: the start position's (from its FEN's side and move number).
    var startPly: Int {
        let fields = startFen.split(separator: " ")
        guard fields.count >= 6, let number = Int(fields[5]) else { return 0 }
        return (number - 1) * 2 + (fields[1] == "b" ? 1 : 0)
    }

    /// The move list's row holding the move on the board, nil at the start.
    var currentRow: Int? {
        moveList.firstIndex { row in
            switch row {
            case .main(let row): row.white?.isCurrent == true || row.black?.isCurrent == true
            case .variation(let row): row.tokens.contains { if case .move(let move) = $0 { move.isCurrent } else { false } }
            }
        }
    }
    var canForward: Bool { observe(); return !session.lineAhead().isEmpty }

    var orientation: Side {
        get { observe(); return session.orientation() }
        set { session.setOrientation(side: newValue); stamp += 1 }
    }

    /// What the engine analyses: the position on the board.
    var engineKey: EngineService.Key {
        EngineService.Key(startFen: startFen, moves: movesToBoard.map(\.uci))
    }

    func isMainLine(_ id: UInt32) -> Bool { session.isMainLine(id: id) }

    // MARK: Moves

    func play(from: BoardSquare, to: BoardSquare, promotion: PieceKind?) {
        act(session.play(from: from, to: to, promotion: promotion))
    }

    func play(uci: String) { act(session.playUci(uci: uci)) }
    func go(to id: UInt32) { act(session.go(id: id)) }
    func back() { act(session.back()) }

    /// Goes to the move `plies` half-moves into the history strip's line: back along the moves
    /// to the board, or forward along the line ahead (0: the start).
    func go(toPly plies: Int) {
        let here = session.movesToBoard().count
        var changed = false
        if plies < here {
            for _ in plies..<here { changed = session.back() || changed }
        } else {
            for _ in here..<plies { changed = session.forward() || changed }
        }
        act(changed)
    }
    func forward() { act(session.forward()) }

    func promote(_ id: UInt32) { act(session.promote(id: id)) }
    func makeMainLine(_ id: UInt32) { act(session.makeMainLine(id: id)) }
    func delete(from id: UInt32) { act(session.deleteFrom(id: id)) }

    /// Records the engine's evaluation of the position on the board for the move list.
    func setEval(_ eval: NodeEval) {
        session.setEval(eval: eval)
        stamp += 1
    }

    func linePGN(_ id: UInt32) -> String { session.linePgn(id: id) }
    var pgn: String { session.pgn() }

    /// Leaves the board, once its screen is popped (not when something only covers it): Browse
    /// gets the line to the selected move as its draft (saved moves are followed, nothing is
    /// written); Study drops it.
    func finish() {
        guard !finished else { return }
        finished = true
        if case .build(let builder) = origin {
            builder.setLine(session.movesToBoard())
        }
    }
}
