import Foundation

/// Card bookkeeping and line selection for a repertoire.
///
/// A card is a position (EPD) where it is your move and the repertoire has a main move.
/// Transposed positions share one card. Alternative moves of yours (not the first) and
/// everything below them are not trained. A line that ends in a position whose moves are
/// stored at another node continues there.
public struct Trainer: Sendable {
    public let tree: RepertoireTree
    public let color: Side
    /// Nodes on main lines (not below an alternative move of yours).
    public let trainable: Set<NodeID>
    /// All card positions, computed once: study sessions test every card against it.
    public private(set) var cardEPDSet: Set<EPD> = []

    public init(tree: RepertoireTree, color: Side) {
        self.tree = tree
        self.color = color
        var trainable: Set<NodeID> = []
        var stack = [RepertoireTree.rootID]
        while let id = stack.popLast() {
            guard tree[id] != nil, trainable.insert(id).inserted else { continue }
            stack.append(contentsOf: Self.next(after: id, tree: tree, color: color))
        }
        self.trainable = trainable
        cardEPDSet = cardEPDs()
    }

    /// Nodes a line continues to: your main move, every opponent reply, or for a position
    /// whose moves are stored elsewhere, that node's continuations.
    private static func next(after id: NodeID, tree: RepertoireTree, color: Side) -> [NodeID] {
        guard let node = tree[id] else { return [] }
        let holder = node.children.isEmpty ? tree.transpositionTarget(of: id).flatMap { tree[$0] } : node
        guard let holder else { return [] }
        return holder.sideToMove == color ? Array(holder.children.prefix(1)) : holder.children
    }

    func next(after id: NodeID) -> [NodeID] {
        Self.next(after: id, tree: tree, color: color)
    }

    /// Trainable nodes below `root`, following transpositions, each once.
    func reachable(under root: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var seen: Set<NodeID> = []
        var stack = [root]
        while let id = stack.popLast() {
            guard trainable.contains(id), seen.insert(id).inserted else { continue }
            result.append(id)
            stack.append(contentsOf: next(after: id).reversed())
        }
        return result
    }

    /// Your-turn nodes with a main move, i.e. where a card is asked.
    public func cardNodes(under root: NodeID = RepertoireTree.rootID) -> [NodeID] {
        reachable(under: root).filter { id in
            guard let node = tree[id] else { return false }
            return node.sideToMove == color && !node.children.isEmpty
        }
    }

    public func cardEPDs(under root: NodeID = RepertoireTree.rootID) -> Set<EPD> {
        Set(cardNodes(under: root).compactMap { tree[$0]?.epd })
    }

    /// Your-turn positions with a move saved that are only reached below an alternative move
    /// of yours. Their cards are suspended (as in Anki), so a line keeps its progress when it
    /// stops being the main line and gets it back when it is the main line again.
    public func suspendedCardEPDs(under root: NodeID = RepertoireTree.rootID) -> Set<EPD> {
        let active = cardEPDSet
        var result: Set<EPD> = []
        for id in tree.subtree(of: root) where !trainable.contains(id) {
            guard let node = tree[id], node.sideToMove == color, !node.children.isEmpty,
                  !active.contains(node.epd) else { continue }
            result.insert(node.epd)
        }
        return result
    }

    /// The main move for a card position (first node with that EPD that has one).
    public func expectedMove(at id: NodeID) -> PlayedMove? {
        guard let node = tree[id] else { return nil }
        if let main = node.children.first { return tree[main]?.move }
        for other in tree.epdIndex[node.epd] ?? [] where trainable.contains(other) {
            if let main = tree[other]?.children.first { return tree[main]?.move }
        }
        return nil
    }

    // MARK: Progress

    /// Your moves by Anki's card-count groups: learning (learn and relearn), young (review
    /// interval under 21 days) and mature.
    public struct Progress: Sendable, Equatable {
        public var cards = 0
        public var learning = 0
        public var young = 0
        public var mature = 0
        /// Positions below your alternative moves; not part of `cards`.
        public var suspended = 0

        public init(cards: Int = 0, learning: Int = 0, young: Int = 0, mature: Int = 0, suspended: Int = 0) {
            self.cards = cards
            self.learning = learning
            self.young = young
            self.mature = mature
            self.suspended = suspended
        }

        public var studied: Int { learning + young + mature }

        public mutating func add(_ card: Card) {
            guard card.queue != .suspended else { return }
            switch card.ctype {
            case .new: break
            case .learn, .relearn: learning += 1
            case .review: if card.interval < GraphsContext.matureInterval { young += 1 } else { mature += 1 }
            }
        }
        public var notStudied: Int { cards - studied }
    }

    public func progress(under root: NodeID = RepertoireTree.rootID, cards: [EPD: Card]) -> Progress {
        var p = Progress()
        for epd in cardEPDs(under: root) {
            p.cards += 1
            if let card = cards[epd] { p.add(card) }
        }
        p.suspended = suspendedCardEPDs(under: root).count
        return p
    }

    // MARK: Lines

    /// A line from the root to a leaf. The user plays all their moves along it.
    public struct Line: Sendable, Equatable {
        public let nodes: [NodeID]
    }

    /// Every line below `root` once (for "train this branch").
    public func allLines(under root: NodeID) -> [Line] {
        guard trainable.contains(root) else { return [] }
        var lines: [Line] = []
        // A transposed position's continuation is drilled once: lines into a position stored
        // inside this branch end there, and one stored elsewhere is entered by one line only.
        var continued: Set<NodeID> = []
        var stack: [[NodeID]] = [tree.path(to: root)]
        while let line = stack.popLast() {
            let id = line.last!
            var nextNodes = next(after: id).filter(trainable.contains)
            if tree[id]?.children.isEmpty == true, let target = tree.transpositionTarget(of: id),
               target == root || tree.isAncestor(root, of: target) || !continued.insert(target).inserted {
                nextNodes = []
            }
            if nextNodes.isEmpty {
                lines.append(Line(nodes: line))
            } else {
                for n in nextNodes.reversed() { stack.append(line + [n]) }
            }
        }
        return lines
    }

    /// Path to `target`, continued to a leaf choosing opponent moves by `preferring`.
    public func line(through target: NodeID, preferring score: (NodeID) -> Double = { _ in 1 }) -> Line {
        var nodes = tree.path(to: target)
        var visited = Set(nodes)
        var cursor = target
        while true {
            let options = next(after: cursor).filter { trainable.contains($0) && !visited.contains($0) }
            guard let next = options.max(by: { score($0) < score($1) }) else { break }
            nodes.append(next)
            visited.insert(next)
            cursor = next
        }
        return Line(nodes: nodes)
    }
}

/// Plays one line: the app plays the opponent's moves, the user plays theirs.
/// Modeled on the Lichess gamebook flow (play / good / bad / end).
public struct LineRun: Sendable {
    public enum Outcome: Equatable, Sendable {
        case correct
        /// A saved alternative move of yours, not the main one. Try again, no penalty.
        case alternative
        case wrong(expected: PlayedMove)
    }

    public let trainer: Trainer
    public let nodes: [NodeID]
    /// Index into `nodes` of the position on the board.
    public private(set) var index = 0

    public init(trainer: Trainer, nodes: [NodeID]) {
        self.trainer = trainer
        self.nodes = nodes
    }

    public var currentNode: NodeID { nodes[index] }
    public var isFinished: Bool { index >= nodes.count - 1 }
    /// Your move is next on the line (it may still be played for you).
    public var isOwnTurn: Bool {
        !isFinished && trainer.tree[currentNode]?.sideToMove == trainer.color
    }

    /// The move to play now.
    public var expected: PlayedMove? {
        guard !isFinished else { return nil }
        return trainer.tree[nodes[index + 1]]?.move
    }

    /// Plays the next move on the line (opponent's, or yours played for you).
    @discardableResult
    public mutating func advance() -> PlayedMove? {
        guard !isFinished else { return nil }
        index += 1
        return trainer.tree[currentNode]?.move
    }

    /// Checks the user's move; advances when it is the expected one.
    public mutating func userPlayed(uci: String) -> Outcome {
        guard let expected, let node = trainer.tree[currentNode] else { return .correct }
        if uci == expected.uci {
            index += 1
            return .correct
        }
        let holder = node.children.isEmpty ? trainer.tree.transpositionTarget(of: node.id).flatMap { trainer.tree[$0] } ?? node : node
        if holder.children.dropFirst().contains(where: { trainer.tree[$0]?.move?.uci == uci }) {
            return .alternative
        }
        return .wrong(expected: expected)
    }
}
