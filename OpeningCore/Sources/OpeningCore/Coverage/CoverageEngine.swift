import Foundation

public struct CoverageSettings: Codable, Sendable, Hashable {
    public var color: Side
    /// Cover every opponent move seen at least once in `targetGames` games.
    public var targetGames: Int
    /// Positions with fewer explorer games create no requirements.
    public var minGames: Int
    /// Opponent moves (UCI) you chose not to cover, by the position before them. They are
    /// never required and never gaps. A move you save anyway is covered as usual.
    public var excluded: [EPD: Set<String>]

    public init(color: Side, targetGames: Int = 500, minGames: Int = 25, excluded: [EPD: Set<String>] = [:]) {
        self.color = color
        self.targetGames = targetGames
        self.minGames = minGames
        self.excluded = excluded
    }

    public var threshold: Double { 1 / Double(max(targetGames, 1)) }

    public func isExcluded(_ uci: String, at epd: EPD) -> Bool {
        excluded[epd]?.contains(uci) == true
    }
}

public struct CoverageGap: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Your move is missing in this position.
        case missingMove
        /// A required opponent reply is missing below this position.
        case missingReply(uci: String, san: String)
    }

    public let node: NodeID
    public let kind: Kind
    /// Reach probability of the uncovered position.
    public let mass: Double

    /// "Seen once every N games".
    public var seenEvery: Int { mass > 0 ? Int((1 / mass).rounded()) : .max }
}

/// An opponent reply at an opponent-to-move node, as listed in the builder.
public struct ReplyInfo: Hashable, Sendable {
    public let uci: String
    public let san: String
    public let share: Double
    public let reach: Double
    public let required: Bool
    /// Not in the repertoire and excluded from coverage.
    public let excluded: Bool
    /// The child node if the reply is in the repertoire.
    public let child: NodeID?
    /// A node elsewhere with the same position and a move of yours.
    public let transposesTo: NodeID?
    public let completion: Double
    public let games: Int
}

public struct NodeCoverage: Sendable {
    public enum Status: Hashable, Sendable {
        /// Inside the required region and has what it needs (completion may still be < 1 below it).
        case required
        /// Reach below the target: nothing is required here.
        case belowTarget
        /// Opponent to move, stats not fetched yet.
        case pending
        /// Reach unknown because an ancestor is pending.
        case unknown
        /// Your move is missing.
        case gap
        /// Your move is missing here, but the same position is covered at another node.
        case transposition(NodeID)
        /// An alternative move of yours (not the main one); carries no mass.
        case alternative
    }

    public internal(set) var reach: Double?
    public internal(set) var status: Status = .unknown
    public internal(set) var completion: Double = 0
    public internal(set) var gapCount = 0
    public internal(set) var gapMass: Double = 0
    public internal(set) var pendingCount = 0
    public internal(set) var biggestGap: CoverageGap?
    public internal(set) var localGaps: [CoverageGap] = []
    /// For opponent-to-move nodes with stats: explorer replies plus tree children not in the stats.
    public internal(set) var replies: [ReplyInfo] = []
    /// Whether this node counts toward its parent (false under alternatives).
    public internal(set) var counts = true

    public var seenEvery: Int? {
        guard let reach, reach > 0 else { return nil }
        return Int((1 / reach).rounded())
    }
}

/// Computes reach probability, completion and gaps for a repertoire.
///
/// Values are cached per node. After an edit only the edited subtree and its ancestors are
/// recomputed; when stats arrive for a position only the nodes with that EPD are. A full
/// recompute is needed only when settings or the database change.
public struct CoverageEngine: Sendable {
    public typealias StatsLookup = (EPD) -> ExplorerStats?

    public var settings: CoverageSettings
    public private(set) var info: [NodeID: NodeCoverage] = [:]

    /// canonical node -> nodes whose completion depends on it through a transposition.
    private var referrers: [NodeID: Set<NodeID>] = [:]
    /// node -> canonical nodes it references.
    private var references: [NodeID: Set<NodeID>] = [:]
    /// (node, reply uci) -> EPD after the reply, cached because it needs a move replay.
    private var replyEPDs: [String: EPD] = [:]
    private var changedCanonicals: Set<NodeID> = []

    public init(settings: CoverageSettings) {
        self.settings = settings
    }

    public subscript(id: NodeID) -> NodeCoverage? { info[id] }
    public var root: NodeCoverage? { info[RepertoireTree.rootID] }

    // MARK: Public updates

    public mutating func recomputeAll(tree: RepertoireTree, stats: StatsLookup) {
        info = [:]
        referrers = [:]
        references = [:]
        changedCanonicals = []
        computeSubtree(RepertoireTree.rootID, reach: 1, mode: .normal, tree: tree, stats: stats)
        // Canonical nodes may have been computed after the nodes that reference them.
        changedCanonicals = Set(referrers.keys)
        propagateTranspositions(tree: tree, stats: stats)
    }

    /// Call after moves were added, deleted or promoted below `node` (pass the parent of a
    /// deleted node). `epds` are the positions of nodes that were added or removed, so
    /// transpositions into them elsewhere get refreshed.
    public mutating func update(changedAt node: NodeID, epds: Set<EPD> = [], tree: RepertoireTree, stats: StatsLookup) {
        guard tree[node] != nil else {
            recomputeAll(tree: tree, stats: stats)
            return
        }
        forgetMissing(tree: tree)
        let current = info[node]
        computeSubtree(node, reach: current?.reach, mode: mode(of: node, tree: tree), tree: tree, stats: stats)
        refreshAncestors(of: node, tree: tree, stats: stats)
        refresh(epds: epds, excluding: node, tree: tree, stats: stats)
        propagateTranspositions(tree: tree, stats: stats)
    }

    /// Call when explorer stats for `epd` arrived.
    public mutating func statsArrived(for epd: EPD, tree: RepertoireTree, stats: StatsLookup) {
        guard let ids = tree.epdIndex[epd] else { return }
        for id in ids where info[id] != nil {
            computeSubtree(id, reach: info[id]?.reach, mode: mode(of: id, tree: tree), tree: tree, stats: stats)
            refreshAncestors(of: id, tree: tree, stats: stats)
        }
        // Missing replies that lead into this position may now have a different status.
        propagateTranspositions(tree: tree, stats: stats)
    }

    /// Call after the excluded moves at `epd` changed in `settings`.
    public mutating func exclusionsChanged(at epd: EPD, tree: RepertoireTree, stats: StatsLookup) {
        guard let ids = tree.epdIndex[epd] else { return }
        for id in ids where info[id] != nil {
            aggregate(id, tree: tree, stats: stats)
            refreshAncestors(of: id, tree: tree, stats: stats)
        }
        propagateTranspositions(tree: tree, stats: stats)
    }

    /// Replies at a position that is not in the repertoire (a draft on the board), reached with
    /// probability `reach`. None of them is covered yet.
    public func replies(at epd: EPD, stats: ExplorerStats, reach: Double?) -> [ReplyInfo] {
        let enough = stats.total >= settings.minGames
        return stats.moves.map { move in
            let share = stats.total > 0 ? Double(move.games) / Double(stats.total) : 0
            let r = (reach ?? 0) * share
            let excluded = settings.isExcluded(move.uci, at: epd)
            let required = enough && reach != nil && r >= settings.threshold && !excluded
            return ReplyInfo(uci: move.uci, san: move.san, share: share, reach: r, required: required,
                             excluded: excluded, child: nil, transposesTo: nil, completion: 0, games: move.games)
        }
    }

    /// Positions whose stats are needed, biggest reach first.
    public func pendingPositions(tree: RepertoireTree) -> [(epd: EPD, reach: Double)] {
        var best: [EPD: Double] = [:]
        for (id, c) in info where c.status == .pending && c.counts {
            guard let epd = tree[id]?.epd, let r = c.reach else { continue }
            best[epd] = max(best[epd] ?? 0, r)
        }
        return best.map { ($0.key, $0.value) }.sorted { $0.reach > $1.reach }
    }

    /// All gaps, biggest first.
    public func gaps() -> [CoverageGap] {
        info.values.filter(\.counts).flatMap(\.localGaps).sorted {
            $0.mass != $1.mass ? $0.mass > $1.mass : $0.node < $1.node
        }
    }

    // MARK: Computation

    private enum Mode { case normal, alternative }

    private func mode(of id: NodeID, tree: RepertoireTree) -> Mode {
        var cursor = id
        while let node = tree[cursor], let parent = node.parent, let p = tree[parent] {
            if p.sideToMove == settings.color, p.children.first != cursor { return .alternative }
            cursor = parent
        }
        return .normal
    }

    private mutating func computeSubtree(_ id: NodeID, reach: Double?, mode: Mode, tree: RepertoireTree, stats: StatsLookup) {
        guard let node = tree[id] else { return }
        var c = info[id] ?? NodeCoverage()
        c.reach = reach
        c.counts = mode == .normal
        info[id] = c

        let opponentToMove = node.sideToMove != settings.color
        let nodeStats = opponentToMove ? stats(node.epd) : nil
        for (index, child) in node.children.enumerated() {
            guard let childNode = tree[child], let move = childNode.move else { continue }
            var childReach: Double?
            if opponentToMove {
                if let reach, let nodeStats { childReach = reach * nodeStats.share(of: move.uci) }
            } else {
                childReach = reach
            }
            let childMode: Mode = mode == .alternative || (!opponentToMove && index > 0) ? .alternative : .normal
            computeSubtree(child, reach: childReach, mode: childMode, tree: tree, stats: stats)
        }
        aggregate(id, tree: tree, stats: stats)
    }

    private mutating func refreshAncestors(of id: NodeID, tree: RepertoireTree, stats: StatsLookup) {
        var cursor = tree[id]?.parent
        while let c = cursor {
            aggregate(c, tree: tree, stats: stats)
            cursor = tree[c]?.parent
        }
    }

    /// Recomputes one node from its own data and its children's cached values.
    private mutating func aggregate(_ id: NodeID, tree: RepertoireTree, stats: StatsLookup) {
        guard let node = tree[id], var c = info[id] else { return }
        let old = c.completion
        let t = settings.threshold
        setReferences(of: id, to: [])

        c.localGaps = []
        c.replies = []
        c.gapCount = 0
        c.gapMass = 0
        c.pendingCount = 0
        c.biggestGap = nil

        func add(child: NodeCoverage) {
            guard child.counts else { return }
            c.gapCount += child.gapCount
            c.gapMass += child.gapMass
            c.pendingCount += child.pendingCount
            if let g = child.biggestGap, g.mass > (c.biggestGap?.mass ?? -1) { c.biggestGap = g }
        }

        let opponentToMove = node.sideToMove != settings.color
        let nodeStats = opponentToMove ? stats(node.epd) : nil
        if opponentToMove, let nodeStats {
            c.replies = replies(for: node, stats: nodeStats, reach: c.reach, tree: tree)
        }

        if !c.counts {
            c.status = .alternative
            c.completion = node.children.first.flatMap { info[$0]?.completion } ?? 0
        } else if c.reach == nil {
            c.status = .unknown
            c.completion = 0
        } else if c.reach! < t {
            c.status = .belowTarget
            c.completion = 1
        } else if node.children.isEmpty, let canonical = canonicalNode(for: node.epd, excluding: id, tree: tree) {
            // The lines continue at another node with this position (either side to move).
            c.status = .transposition(canonical)
            c.completion = info[canonical]?.completion ?? 0
            setReferences(of: id, to: [canonical])
        } else if !opponentToMove {
            if let main = node.children.first, let mainInfo = info[main] {
                c.status = .required
                c.completion = mainInfo.completion
                add(child: mainInfo)
            } else {
                c.status = .gap
                c.completion = 0
                let gap = CoverageGap(node: id, kind: .missingMove, mass: c.reach!)
                c.localGaps = [gap]
            }
        } else if let nodeStats {
            c.status = .required
            for child in node.children { if let ci = info[child] { add(child: ci) } }
            var weighted = 0.0
            var totalShare = 0.0
            var refs: Set<NodeID> = []
            if nodeStats.total >= settings.minGames {
                for reply in c.replies where reply.required {
                    totalShare += reply.share
                    if reply.child != nil {
                        weighted += reply.share * reply.completion
                    } else if let canonical = reply.transposesTo {
                        refs.insert(canonical)
                        weighted += reply.share * reply.completion
                    } else {
                        c.localGaps.append(CoverageGap(node: id, kind: .missingReply(uci: reply.uci, san: reply.san), mass: reply.reach))
                    }
                }
            }
            setReferences(of: id, to: refs)
            c.completion = totalShare > 0 ? weighted / totalShare : 1
        } else {
            c.status = .pending
            c.completion = 0
            c.pendingCount = 1
        }

        for gap in c.localGaps {
            c.gapCount += 1
            c.gapMass += gap.mass
            if gap.mass > (c.biggestGap?.mass ?? -1) { c.biggestGap = gap }
        }
        info[id] = c
        if old != c.completion, referrers[id]?.isEmpty == false { changedCanonicals.insert(id) }
    }

    private mutating func replies(for node: RepertoireNode, stats: ExplorerStats, reach: Double?, tree: RepertoireTree) -> [ReplyInfo] {
        let t = settings.threshold
        let enough = stats.total >= settings.minGames
        var result: [ReplyInfo] = []
        var seen: Set<String> = []
        for move in stats.moves {
            seen.insert(move.uci)
            let share = stats.total > 0 ? Double(move.games) / Double(stats.total) : 0
            let r = (reach ?? 0) * share
            let child = tree.child(of: node.id, uci: move.uci)
            let excluded = child == nil && settings.isExcluded(move.uci, at: node.epd)
            let required = enough && reach != nil && r >= t && !excluded
            var transposesTo: NodeID?
            var completion = child.flatMap { info[$0]?.completion } ?? 0
            if child == nil, required, let epd = replyEPD(node: node, uci: move.uci) {
                transposesTo = canonicalNode(for: epd, excluding: node.id, tree: tree)
                if let tr = transposesTo { completion = info[tr]?.completion ?? 0 }
            }
            result.append(ReplyInfo(uci: move.uci, san: move.san, share: share, reach: r, required: required,
                                    excluded: excluded, child: child, transposesTo: transposesTo, completion: completion, games: move.games))
        }
        for childID in node.children {
            guard let child = tree[childID], let move = child.move, !seen.contains(move.uci) else { continue }
            result.append(ReplyInfo(uci: move.uci, san: move.san, share: 0, reach: 0, required: false,
                                    excluded: false, child: childID, transposesTo: nil, completion: info[childID]?.completion ?? 0, games: 0))
        }
        return result
    }

    private mutating func replyEPD(node: RepertoireNode, uci: String) -> EPD? {
        let key = "\(node.id)|\(uci)"
        if let cached = replyEPDs[key] { return cached }
        guard let (_, next) = node.position.play(uci: uci) else { return nil }
        replyEPDs[key] = next.epd
        return next.epd
    }

    /// The node with this position where you have a move, if it is not `id` or above it.
    private func canonicalNode(for epd: EPD, excluding id: NodeID, tree: RepertoireTree) -> NodeID? {
        guard let candidates = tree.epdIndex[epd] else { return nil }
        return candidates.sorted().first { candidate in
            candidate != id && tree[candidate]?.children.isEmpty == false
                && !tree.isAncestor(candidate, of: id)
                && info[candidate]?.counts != false
        }
    }

    private mutating func setReferences(of id: NodeID, to canonicals: Set<NodeID>) {
        for old in references[id] ?? [] { referrers[old]?.remove(id) }
        references[id] = canonicals.isEmpty ? nil : canonicals
        for c in canonicals { referrers[c, default: []].insert(id) }
    }

    /// Re-aggregates nodes that reference a canonical node whose completion changed.
    private mutating func propagateTranspositions(tree: RepertoireTree, stats: StatsLookup) {
        var iterations = 0
        while !changedCanonicals.isEmpty, iterations < 10_000 {
            iterations += 1
            let canonical = changedCanonicals.removeFirst()
            for referrer in referrers[canonical] ?? [] where tree[referrer] != nil {
                aggregate(referrer, tree: tree, stats: stats)
                refreshAncestors(of: referrer, tree: tree, stats: stats)
            }
        }
    }

    /// Re-aggregates nodes elsewhere whose transposition status may depend on `epds`.
    private mutating func refresh(epds: Set<EPD>, excluding: NodeID, tree: RepertoireTree, stats: StatsLookup) {
        guard !epds.isEmpty else { return }
        var targets: Set<NodeID> = []
        for epd in epds {
            for id in tree.epdIndex[epd] ?? [] where id != excluding { targets.insert(id) }
        }
        // Opponent nodes with a required reply leading into one of these positions.
        for (key, epd) in replyEPDs where epds.contains(epd) {
            if let id = Int(key.split(separator: "|")[0]) { targets.insert(id) }
        }
        for id in targets where tree[id] != nil && info[id] != nil {
            aggregate(id, tree: tree, stats: stats)
            refreshAncestors(of: id, tree: tree, stats: stats)
        }
    }

    /// Drops cached values of deleted nodes.
    private mutating func forgetMissing(tree: RepertoireTree) {
        for id in info.keys where tree[id] == nil {
            info[id] = nil
            setReferences(of: id, to: [])
            referrers[id] = nil
        }
    }
}
