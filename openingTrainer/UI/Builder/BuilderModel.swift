import Foundation
import Observation
import OpeningCore

/// Navigation state of the builder: the current node plus a draft of moves played on the
/// board that are not saved yet.
@Observable
final class BuilderModel {
    let document: RepertoireDocument
    var current: NodeID = RepertoireTree.rootID
    /// Moves played past `current` that are not in the repertoire yet.
    private(set) var draft: [PlayedMove] = []
    var orientation: Side

    /// False while browsing from a drill, so the builder's last position is not overwritten.
    private let remembersPosition: Bool

    init(document: RepertoireDocument, start: NodeID? = nil) {
        self.document = document
        orientation = document.color
        remembersPosition = start == nil
        if let start, document.tree[start] != nil {
            current = start
        } else if let last = document.sidecar.lastLine, let node = document.tree.node(followingUCI: last) {
            current = node
        }
    }

    var tree: RepertoireTree { document.tree }
    var node: RepertoireNode? { tree[current] }

    /// Position on the board (after the draft).
    var position: ChessPosition {
        var p = node?.position ?? .start
        for move in draft { p = p.play(uci: move.uci)?.1 ?? p }
        return p
    }

    /// When the current position's lines are stored at another node (a transposition), that node.
    var continuation: NodeID? { draft.isEmpty ? tree.transpositionTarget(of: current) : nil }

    /// The node whose moves the panels show: the current one, or where its lines continue.
    var shownNode: RepertoireNode? { continuation.flatMap { tree[$0] } ?? node }

    var canForward: Bool { draft.isEmpty && shownNode?.children.isEmpty == false }

    var lastMove: PlayedMove? { draft.last ?? node?.move }
    var isUserTurnOnBoard: Bool { position.sideToMove == document.color }
    var hasDraft: Bool { !draft.isEmpty }

    /// Moves from the start to the board position, including the draft.
    var movesToBoard: [PlayedMove] { tree.moves(to: current) + draft }

    // MARK: Navigation

    func go(to id: NodeID) {
        guard tree[id] != nil else { return }
        draft = []
        current = id
        remember()
    }

    func back() {
        if !draft.isEmpty {
            draft.removeLast()
        } else if let parent = node?.parent {
            current = parent
            remember()
        }
    }

    func forward() {
        guard draft.isEmpty, let main = shownNode?.children.first else { return }
        current = main
        remember()
    }

    /// Switch to the previous/next sibling line (↑/↓ keys).
    func sibling(_ offset: Int) {
        guard draft.isEmpty, let parent = node?.parent, let siblings = tree[parent]?.children,
              let i = siblings.firstIndex(of: current) else { return }
        let j = (i + offset + siblings.count) % siblings.count
        go(to: siblings[j])
    }

    /// A move made on the board: follows the repertoire if the move exists there,
    /// otherwise extends the draft.
    func play(from: BoardSquare, to: BoardSquare, promotion: PieceKind?) {
        guard let (move, _) = position.play(from: from, to: to, promotion: promotion) else { return }
        play(move)
    }

    func play(uci: String) {
        guard let (move, _) = position.play(uci: uci) else { return }
        play(move)
    }

    private func play(_ move: PlayedMove) {
        if draft.isEmpty, let shown = shownNode, let child = tree.child(of: shown.id, uci: move.uci) {
            go(to: child)
        } else {
            draft.append(move)
        }
    }

    /// Previews a reply or candidate from the panel as a draft move.
    func preview(uci: String) {
        draft = []
        play(uci: uci)
    }

    // MARK: Editing

    func saveDraft() {
        // New moves at a transposition go where that position's lines are stored.
        let parent = tree.transpositionTarget(of: current) ?? current
        guard !draft.isEmpty, let last = document.addLine(draft.map(\.uci), after: parent) else { return }
        draft = []
        current = last
        remember()
    }

    func discardDraft() {
        draft = []
    }

    /// Adds a move from the panel and goes there.
    func add(uci: String) {
        if let id = document.addMove(uci, after: continuation ?? current) {
            go(to: id)
        }
    }

    func delete(_ id: NodeID) {
        if id == current || tree.isAncestor(id, of: current), let parent = tree[id]?.parent {
            go(to: parent)
        }
        document.delete(id)
    }

    /// Goes to the biggest gap below the current node, or in the whole repertoire.
    func goToBiggestGap() {
        let gap = document.coverage[current]?.biggestGap ?? document.coverage.root?.biggestGap
        guard let gap else { return }
        go(to: gap.node)
        if case let .missingReply(uci, _) = gap.kind { play(uci: uci) }
    }

    func go(to gap: CoverageGap) {
        go(to: gap.node)
        if case let .missingReply(uci, _) = gap.kind { play(uci: uci) }
    }

    private func remember() {
        guard remembersPosition else { return }
        document.rememberLine(tree.moves(to: current).map(\.uci))
    }

    /// Arrows for the current node: your saved moves, or the opponent's replies sized by
    /// frequency with missing required replies as dashed orange arrows.
    var arrows: [BoardArrow] {
        guard draft.isEmpty, let node = shownNode else { return [] }
        if node.sideToMove == document.color {
            return node.children.enumerated().compactMap { i, child in
                guard let move = tree[child]?.move else { return nil }
                return BoardArrow(from: move.from, to: move.to, style: .mine, width: i == 0 ? 0.2 : 0.12, opacity: i == 0 ? 0.85 : 0.5)
            }
        }
        guard let replies = document.coverage[node.id]?.replies, !replies.isEmpty else {
            return node.children.compactMap { child in
                tree[child]?.move.map { BoardArrow(from: $0.from, to: $0.to, style: .opponent, width: 0.12, opacity: 0.6) }
            }
        }
        let maxShare = replies.map(\.share).max() ?? 1
        return replies.prefix(6).compactMap { reply in
            guard let from = BoardSquare(reply.uci.prefix(2)), let to = BoardSquare(reply.uci.dropFirst(2).prefix(2)) else { return nil }
            let inRepertoire = reply.child != nil || reply.transposesTo != nil
            if !inRepertoire && !reply.required { return nil }
            let rel = maxShare > 0 ? reply.share / maxShare : 0
            return BoardArrow(from: from, to: to, style: inRepertoire ? .opponent : .gap,
                              width: 0.04 + 0.14 * rel, opacity: 0.3 + 0.6 * rel, dashed: !inRepertoire)
        }
    }
}
