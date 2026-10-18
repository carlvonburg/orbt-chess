import Foundation

/// Who plays your moves on the way to the move being asked (Chessbook's practice options).
/// Every line starts from the initial position and shows every move.
public enum PracticeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The app plays all moves up to the ones being asked.
    case individualMoves
    /// You play all your moves, every line.
    case completeLinesEveryTime
    /// You play all your moves the first time they come up in a session; then the app does.
    case completeLinesOncePerSession

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .individualMoves: "Individual moves"
        case .completeLinesEveryTime: "Complete lines (every time)"
        case .completeLinesOncePerSession: "Complete lines (once per session)"
        }
    }

    public static let `default` = PracticeMode.completeLinesOncePerSession
}

/// How one of your moves on a study line is handled.
public enum MoveRole: Equatable, Sendable {
    /// Played for you.
    case auto
    /// You play it; nothing is recorded (it was answered earlier this session).
    case practice
    /// You play it and it is answered as an Anki card.
    case answer(AnswerKind)

    public var isAsked: Bool {
        if case .answer = self { return true }
        return false
    }
}

public enum AnswerKind: Equatable, Sendable {
    /// In today's queue: answered normally.
    case queued
    /// A New card: shown first, then answered.
    case introduce
    /// Not due: answered early, like a card in an Anki filtered deck.
    case reviewAhead
}

public struct StudyLine: Sendable, Equatable {
    public let nodes: [NodeID]
    /// The role of your move from `nodes[i]`, for each index where it's your turn.
    public let roles: [Int: MoveRole]
    /// The queued card the line was built for.
    public let target: EPD
}

/// A study session over Anki's queue: picks the next card, builds a line to it, and keeps
/// track of what was answered and played in this session.
public struct StudySession: Sendable {
    public let trainer: Trainer
    public let mode: PracticeMode
    /// A branch session (Anki filtered deck with rescheduling): no daily limits, cards
    /// answered with their real due date.
    public let isFiltered: Bool
    public let root: NodeID
    public private(set) var queue: CardQueues
    /// Cards answered this session.
    public private(set) var answered: Set<EPD> = []
    /// Cards the user played correctly this session.
    public private(set) var played: Set<EPD> = []
    let newIndex: [EPD: Int]
    let reach: [NodeID: Double]

    /// A daily session over the whole repertoire.
    public init(trainer: Trainer, mode: PracticeMode, cards: [EPD: Card], limits: RemainingLimits,
                timing: SchedTiming, learnAheadSecs: Int = 1200, reach: [NodeID: Double] = [:]) {
        self.trainer = trainer
        self.mode = mode
        self.reach = reach
        isFiltered = false
        root = RepertoireTree.rootID
        let order = trainer.newCardOrder(reach: reach)
        newIndex = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let epdReach = trainer.reachByEPD(reach)
        queue = CardQueues(cards: cards.filter { trainer.cardEPDSet.contains($0.key) }, newCards: order,
                           limits: limits, timing: timing, learnAheadSecs: learnAheadSecs,
                           priority: { epdReach[$0] ?? 0 })
    }

    /// A branch session: every card under `root`, in random order, without limits.
    public init(trainer: Trainer, mode: PracticeMode, branch root: NodeID, cards: [EPD: Card],
                timing: SchedTiming, learnAheadSecs: Int = 1200, reach: [NodeID: Double] = [:]) {
        self.trainer = trainer
        self.mode = mode
        self.reach = reach
        isFiltered = true
        self.root = root
        let order = trainer.newCardOrder(under: root, reach: reach)
        newIndex = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        queue = CardQueues(filtered: order, cards: cards, timing: timing, learnAheadSecs: learnAheadSecs)
    }

    // MARK: Lines

    /// The line for the next card in the queue, or nil when the session is done.
    public mutating func nextLine(cards: [EPD: Card]) -> StudyLine? {
        while let (epd, _) = queue.next {
            if let line = line(to: epd, cards: cards) { return line }
            // the position is no longer in the repertoire
            queue.remove(epd)
        }
        return nil
    }

    func line(to target: EPD, cards: [EPD: Card]) -> StudyLine? {
        let tree = trainer.tree
        let candidates = (tree.epdIndex[target] ?? []).filter { id in
            trainer.trainable.contains(id) && tree[id]?.sideToMove == trainer.color
                && (id == root || tree.isAncestor(root, of: id))
        }
        // prefer a path whose earlier moves have all been introduced, then the likeliest
        let isNew = { (epd: EPD) in cards[epd] == nil }
        guard let start = candidates.min(by: { a, b in
            let na = newMovesBefore(a, isNew: isNew), nb = newMovesBefore(b, isNew: isNew)
            if na != nb { return na < nb }
            return (reach[a] ?? 0) > (reach[b] ?? 0)
        }) else { return nil }

        var nodes = tree.path(to: start)
        var visited = Set(nodes)
        let newLine = isNew(target)
        var queuedBelow: [NodeID: Int] = [:]
        var firstNewBelow: [NodeID: Int] = [:]
        var cursor = start
        while true {
            let options = trainer.next(after: cursor).filter { trainer.trainable.contains($0) && !visited.contains($0) }
            guard !options.isEmpty else { break }
            let next: NodeID
            if tree[cursor]?.sideToMove == trainer.color || options.count == 1 {
                next = options[0]
            } else if newLine {
                // follow the new-card order: the continuation with the next new card
                next = options.min { a, b in
                    let fa = firstNew(below: a, isNew: isNew, memo: &firstNewBelow)
                    let fb = firstNew(below: b, isNew: isNew, memo: &firstNewBelow)
                    return fa != fb ? fa < fb : (reach[a] ?? 0) > (reach[b] ?? 0)
                }!
            } else {
                // the continuation with the most cards waiting
                next = options.max { a, b in
                    let qa = queued(below: a, memo: &queuedBelow), qb = queued(below: b, memo: &queuedBelow)
                    return qa != qb ? qa < qb : (reach[a] ?? 0) < (reach[b] ?? 0)
                }!
            }
            nodes.append(next)
            visited.insert(next)
            cursor = next
        }

        var roles: [Int: MoveRole] = [:]
        let rootIndex = nodes.firstIndex(of: root) ?? 0
        for i in 0..<(nodes.count - 1) {
            guard let node = tree[nodes[i]], node.sideToMove == trainer.color else { continue }
            roles[i] = i < rootIndex ? .auto : role(for: node.epd, cards: cards)
        }
        // end after the last move that is answered (a queued or new card)
        guard let last = roles.filter({ $0.value == .answer(.queued) || $0.value == .answer(.introduce) }).keys.max()
        else { return nil }
        nodes = Array(nodes[...(last + 1)])
        roles = roles.filter { $0.key <= last }
        return StudyLine(nodes: nodes, roles: roles, target: target)
    }

    func role(for epd: EPD, cards: [EPD: Card]) -> MoveRole {
        let card = cards[epd]
        if card?.queue == .suspended { return .auto }
        if queue.contains(epd) { return card == nil ? .answer(.introduce) : .answer(.queued) }
        if card == nil { return isFiltered ? .auto : .answer(.introduce) }
        switch mode {
        case .individualMoves:
            return .auto
        case .completeLinesEveryTime:
            return answered.contains(epd) || isFiltered ? .practice : .answer(.reviewAhead)
        case .completeLinesOncePerSession:
            if played.contains(epd) { return .auto }
            return answered.contains(epd) || isFiltered ? .practice : .answer(.reviewAhead)
        }
    }

    private func newMovesBefore(_ id: NodeID, isNew: (EPD) -> Bool) -> Int {
        let tree = trainer.tree
        return tree.path(to: id).dropLast().filter { n in
            guard let node = tree[n], node.sideToMove == trainer.color, !node.children.isEmpty else { return false }
            return isNew(node.epd)
        }.count
    }

    private func queued(below id: NodeID, memo: inout [NodeID: Int]) -> Int {
        if let v = memo[id] { return v }
        let v = trainer.reachable(under: id).filter { n in
            guard let node = trainer.tree[n], node.sideToMove == trainer.color else { return false }
            return queue.contains(node.epd)
        }.count
        memo[id] = v
        return v
    }

    private func firstNew(below id: NodeID, isNew: (EPD) -> Bool, memo: inout [NodeID: Int]) -> Int {
        if let v = memo[id] { return v }
        let v = trainer.reachable(under: id).compactMap { n -> Int? in
            guard let epd = trainer.tree[n]?.epd, isNew(epd) else { return nil }
            return newIndex[epd]
        }.min() ?? Int.max
        memo[id] = v
        return v
    }

    /// A new card's position in the new-card order.
    public func position(of epd: EPD) -> Int { newIndex[epd] ?? newIndex.count }

    // MARK: Recording

    /// After a card was answered: removes it from the queue and requeues it if it's
    /// still learning today.
    public mutating func didAnswer(_ epd: EPD, card: Card, timing: SchedTiming) {
        queue.remove(epd)
        queue.answered(card, epd: epd, timing: timing)
        answered.insert(epd)
    }

    public mutating func didPlay(_ epd: EPD) {
        played.insert(epd)
    }

    public mutating func updateLearningCutoff(now: Int64) {
        queue.updateLearningCutoff(now: now)
    }

    /// Custom study "increase today's new limit": rebuilds the queue with the new limits.
    public mutating func rebuild(cards: [EPD: Card], limits: RemainingLimits, timing: SchedTiming, learnAheadSecs: Int = 1200) {
        guard !isFiltered else { return }
        let order = newIndex.sorted { $0.value < $1.value }.map(\.key)
        let epdReach = trainer.reachByEPD(reach)
        queue = CardQueues(cards: cards.filter { trainer.cardEPDSet.contains($0.key) }, newCards: order,
                           limits: limits, timing: timing, learnAheadSecs: learnAheadSecs,
                           priority: { epdReach[$0] ?? 0 })
    }
}

extension Trainer {
    /// New-card order: depth first, the most reached continuation first, so a line is
    /// learned before the next one.
    public func newCardOrder(under root: NodeID = RepertoireTree.rootID, reach: [NodeID: Double] = [:]) -> [EPD] {
        var order: [EPD] = []
        var seen: Set<EPD> = []
        var visited: Set<NodeID> = []
        var stack = [root]
        while let id = stack.popLast() {
            guard trainable.contains(id), visited.insert(id).inserted, let node = tree[id] else { continue }
            var nexts = next(after: id)
            if node.sideToMove == color {
                if !nexts.isEmpty, seen.insert(node.epd).inserted { order.append(node.epd) }
            } else {
                nexts.sort { (reach[$0] ?? 0) > (reach[$1] ?? 0) }
            }
            stack.append(contentsOf: nexts.reversed())
        }
        return order
    }

    /// The highest reach of any node with each position.
    func reachByEPD(_ reach: [NodeID: Double]) -> [EPD: Double] {
        var result: [EPD: Double] = [:]
        for (id, r) in reach {
            guard let epd = tree[id]?.epd else { continue }
            result[epd] = max(result[epd] ?? 0, r)
        }
        return result
    }
}
