import Foundation

/// Card bookkeeping and line selection for a repertoire.
///
/// A card is a position (EPD) where it is your move and the repertoire has a main move.
/// Transposed positions share one card. Alternative moves of yours (not the first) and
/// everything below them are not trained.
public struct Trainer: Sendable {
    public let tree: RepertoireTree
    public let color: Side
    /// Nodes on main lines (not below an alternative move of yours).
    public let trainable: Set<NodeID>

    public init(tree: RepertoireTree, color: Side) {
        self.tree = tree
        self.color = color
        var trainable: Set<NodeID> = []
        var stack = [RepertoireTree.rootID]
        while let id = stack.popLast() {
            guard let node = tree[id] else { continue }
            trainable.insert(id)
            if node.sideToMove == color {
                if let main = node.children.first { stack.append(main) }
            } else {
                stack.append(contentsOf: node.children)
            }
        }
        self.trainable = trainable
    }

    /// Your-turn nodes with a main move, i.e. where a card is asked.
    public func cardNodes(under root: NodeID = RepertoireTree.rootID) -> [NodeID] {
        tree.subtree(of: root).filter { id in
            guard trainable.contains(id), let node = tree[id] else { return false }
            return node.sideToMove == color && !node.children.isEmpty
        }
    }

    public func cardEPDs(under root: NodeID = RepertoireTree.rootID) -> Set<EPD> {
        Set(cardNodes(under: root).compactMap { tree[$0]?.epd })
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

    public struct Progress: Sendable, Equatable {
        public var cards = 0
        public var seen = 0
        public var mature = 0
        public var due = 0

        public var seenFraction: Double { cards > 0 ? Double(seen) / Double(cards) : 0 }
        public var matureFraction: Double { cards > 0 ? Double(mature) / Double(cards) : 0 }
    }

    public func progress(under root: NodeID = RepertoireTree.rootID, cards: [EPD: CardState], now: Date = .now) -> Progress {
        var p = Progress()
        for epd in cardEPDs(under: root) {
            p.cards += 1
            guard let card = cards[epd] else { continue }
            p.seen += 1
            if card.isMature { p.mature += 1 }
            if card.isDue(at: now) { p.due += 1 }
        }
        return p
    }

    // MARK: Lines

    /// A line from the root to a leaf. The user plays all their moves along it.
    public struct Line: Sendable, Equatable {
        public let nodes: [NodeID]
    }

    /// One line through the due card with the highest weight, continued to a leaf
    /// preferring branches with more due cards.
    public func nextDueLine(cards: [EPD: CardState], now: Date = .now, under root: NodeID = RepertoireTree.rootID,
                            excluding done: Set<EPD> = [], weight: (NodeID) -> Double = { _ in 1 }) -> Line? {
        let due = cardNodes(under: root).filter { id in
            guard let epd = tree[id]?.epd, !done.contains(epd), let card = cards[epd] else { return false }
            return card.isDue(at: now)
        }
        guard let target = due.max(by: { lhs, rhs in
            let wl = weight(lhs), wr = weight(rhs)
            return wl != wr ? wl < wr : lhs > rhs
        }) else { return nil }
        let dueEPDs = Set(due.compactMap { tree[$0]?.epd })
        return line(through: target) { id in
            dueCount(under: id, dueEPDs: dueEPDs) * 10 + weight(id)
        }
    }

    /// One line through the unseen card with the highest weight.
    public func nextNewLine(cards: [EPD: CardState], under root: NodeID = RepertoireTree.rootID,
                            excluding done: Set<EPD> = [], weight: (NodeID) -> Double = { _ in 1 }) -> Line? {
        let unseen = cardNodes(under: root).filter { id in
            guard let epd = tree[id]?.epd else { return false }
            return cards[epd] == nil && !done.contains(epd)
        }
        // Prefer the shallowest, then the most likely position, so lines are learned in order.
        guard let target = unseen.min(by: { lhs, rhs in
            let pl = tree[lhs]!.ply, pr = tree[rhs]!.ply
            if pl != pr { return pl < pr }
            return weight(lhs) > weight(rhs)
        }) else { return nil }
        return line(through: target, preferring: weight)
    }

    /// Every line below `root` once (for "train this branch").
    public func allLines(under root: NodeID) -> [Line] {
        var leaves: [NodeID] = []
        var stack = [root]
        while let id = stack.popLast() {
            guard let node = tree[id], trainable.contains(id) else { continue }
            let next = node.sideToMove == color ? Array(node.children.prefix(1)) : node.children
            if next.isEmpty { leaves.append(id) } else { stack.append(contentsOf: next.reversed()) }
        }
        return leaves.map { Line(nodes: tree.path(to: $0)) }
    }

    /// Path to `target`, continued to a leaf choosing opponent moves by `preferring`.
    public func line(through target: NodeID, preferring score: (NodeID) -> Double = { _ in 1 }) -> Line {
        var nodes = tree.path(to: target)
        var cursor = target
        while let node = tree[cursor] {
            let options = node.sideToMove == color ? Array(node.children.prefix(1)) : node.children.filter(trainable.contains)
            guard let next = options.max(by: { score($0) < score($1) }) else { break }
            nodes.append(next)
            cursor = next
        }
        return Line(nodes: nodes)
    }

    private func dueCount(under id: NodeID, dueEPDs: Set<EPD>) -> Double {
        Double(tree.subtree(of: id).filter { trainable.contains($0) && dueEPDs.contains(tree[$0]!.epd) }.count)
    }
}

/// Plays one line: the app plays the opponent's moves, the user plays theirs.
/// Modeled on the Lichess gamebook flow (play / good / bad / end).
public struct DrillSession: Sendable {
    public enum Outcome: Equatable, Sendable {
        case correct
        /// A saved alternative move of yours, not the main one. Try again, no penalty.
        case alternative
        case wrong(expected: PlayedMove)
    }

    public let trainer: Trainer
    public let line: Trainer.Line
    /// Index into `line.nodes` of the position on the board.
    public private(set) var index = 0
    public private(set) var mistakes: [EPD: Int] = [:]
    public private(set) var hints: Set<EPD> = []

    public init(trainer: Trainer, line: Trainer.Line, startAt startNode: NodeID? = nil) {
        self.trainer = trainer
        self.line = line
        if let startNode, let i = line.nodes.firstIndex(of: startNode) { index = i }
    }

    public var currentNode: NodeID { line.nodes[index] }
    public var isFinished: Bool { index >= line.nodes.count - 1 }
    public var isUserTurn: Bool {
        !isFinished && trainer.tree[currentNode]?.sideToMove == trainer.color
    }

    /// The move the user should play now.
    public var expected: PlayedMove? {
        guard isUserTurn else { return nil }
        return trainer.tree[line.nodes[index + 1]]?.move
    }

    /// Advances one opponent move. Returns the move played.
    public mutating func playOpponent() -> PlayedMove? {
        guard !isFinished, !isUserTurn else { return nil }
        index += 1
        return trainer.tree[currentNode]?.move
    }

    public mutating func userPlayed(uci: String) -> Outcome {
        guard let expected, let node = trainer.tree[currentNode] else { return .correct }
        if uci == expected.uci {
            index += 1
            return .correct
        }
        if node.children.dropFirst().contains(where: { trainer.tree[$0]?.move?.uci == uci }) {
            return .alternative
        }
        mistakes[node.epd, default: 0] += 1
        return .wrong(expected: expected)
    }

    public mutating func useHint() {
        if let epd = trainer.tree[currentNode]?.epd, isUserTurn { hints.insert(epd) }
    }

    /// Grades for every card position in the line the user has passed.
    /// Wrong → again; hint → hard; otherwise good.
    public func grades() -> [EPD: Grade] {
        var result: [EPD: Grade] = [:]
        for i in 0..<index {
            guard let node = trainer.tree[line.nodes[i]], node.sideToMove == trainer.color else { continue }
            if (mistakes[node.epd] ?? 0) > 0 {
                result[node.epd] = .again
            } else if hints.contains(node.epd) {
                result[node.epd] = .hard
            } else if result[node.epd] == nil {
                result[node.epd] = .good
            }
        }
        for (epd, count) in mistakes where count > 0 { result[epd] = .again }
        return result
    }

    /// Applies grades to cards: new and due cards are scheduled; a card that is not due
    /// yet only changes when it was answered wrong.
    public static func apply(_ grades: [EPD: Grade], to cards: inout [EPD: CardState],
                             fsrs: FSRS = FSRS(), now: Date = .now) {
        for (epd, grade) in grades {
            let card = cards[epd]
            if let card, !card.isDue(at: now), grade != .again { continue }
            cards[epd] = fsrs.review(card, grade: grade, now: now)
        }
    }
}
