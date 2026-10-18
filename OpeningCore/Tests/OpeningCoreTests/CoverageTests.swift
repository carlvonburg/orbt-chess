import Testing
@testable import OpeningCore

/// Stats keyed by the SAN line that leads to the position.
struct FixtureStats {
    var byEPD: [EPD: ExplorerStats] = [:]

    mutating func set(_ line: String, _ moves: [(String, Int)]) {
        var p = ChessPosition.start
        for san in line.split(separator: " ") { p = p.play(san: String(san))!.1 }
        let explorerMoves = moves.map { san, games in
            let played = p.play(san: san)!.0
            return ExplorerMove(uci: played.uci, san: played.san, white: games, draws: 0, black: 0)
        }
        let total = moves.reduce(0) { $0 + $1.1 }
        byEPD[p.epd] = ExplorerStats(white: total, draws: 0, black: 0, moves: explorerMoves)
    }

    func lookup(_ epd: EPD) -> ExplorerStats? { byEPD[epd] }
}

extension RepertoireTree {
    @discardableResult
    mutating func add(_ line: String) -> NodeID {
        var cursor = RepertoireTree.rootID
        for san in line.split(separator: " ") { cursor = addMove(san: String(san), after: cursor)! }
        return cursor
    }

    func find(_ line: String) -> NodeID? {
        var cursor = RepertoireTree.rootID
        for san in line.split(separator: " ") {
            guard let next = child(of: cursor, san: String(san)) else { return nil }
            cursor = next
        }
        return cursor
    }
}

struct CoverageTests {
    func fixture() -> (RepertoireTree, FixtureStats) {
        var tree = RepertoireTree()
        tree.add("e4 c5 Nf3 d6 d4 cxd4 Nxd4")
        tree.add("e4 e5 Nf3")
        var stats = FixtureStats()
        stats.set("e4", [("c5", 500), ("e5", 300), ("e6", 150), ("c6", 50)])
        stats.set("e4 c5 Nf3", [("d6", 600), ("Nc6", 400)])
        stats.set("e4 c5 Nf3 d6 d4", [("cxd4", 1000)])
        stats.set("e4 c5 Nf3 d6 d4 cxd4 Nxd4", [("Nf6", 5)])  // below minGames
        return (tree, stats)
    }

    @Test func completionGapsAndPending() throws {
        let (tree, stats) = fixture()
        var engine = CoverageEngine(settings: CoverageSettings(color: .white, targetGames: 10, minGames: 10))
        engine.recomputeAll(tree: tree, stats: stats.lookup)
        let root = try #require(engine.root)
        #expect(abs(root.completion - 0.3 / 0.95) < 1e-9)
        #expect(root.gapCount == 2)
        #expect(abs(root.gapMass - 0.35) < 1e-9)
        #expect(root.pendingCount == 1)
        #expect(root.biggestGap?.kind == .missingReply(uci: "b8c6", san: "Nc6"))
        let nf3 = try #require(tree.find("e4 c5 Nf3"))
        #expect(abs(engine[nf3]!.completion - 0.6) < 1e-9)
        #expect(engine[nf3]!.replies.map(\.san) == ["d6", "Nc6"])
        #expect(engine[tree.find("e4 e5 Nf3")!]!.status == .pending)
        #expect(engine.pendingPositions(tree: tree).count == 1)
        #expect(engine[tree.find("e4")!]!.replies.first { $0.san == "c6" }?.required == false)
        #expect(engine.gaps().map(\.seenEvery) == [5, 7])
    }

    @Test func excludedRepliesAreNotGaps() throws {
        var (tree, stats) = fixture()
        var engine = CoverageEngine(settings: CoverageSettings(color: .white, targetGames: 10, minGames: 10))
        engine.recomputeAll(tree: tree, stats: stats.lookup)
        let e4 = try #require(tree.find("e4"))
        let epd = tree[e4]!.epd

        engine.settings.excluded = [epd: ["e7e6"]]
        engine.exclusionsChanged(at: epd, tree: tree, stats: stats.lookup)
        #expect(engine.root!.gapCount == 1)
        #expect(abs(engine.root!.completion - 0.3 / 0.8) < 1e-9)
        let e6 = try #require(engine[e4]!.replies.first { $0.san == "e6" })
        #expect(e6.excluded && !e6.required)

        // A move you save anyway is covered as usual.
        let leaf = tree.add("e4 e6 d4")
        stats.set("e4 e6 d4", [("d5", 5)])
        engine.update(changedAt: e4, epds: [tree[leaf]!.epd], tree: tree, stats: stats.lookup)
        #expect(engine[e4]!.replies.first { $0.san == "e6" }?.excluded == false)
        #expect(abs(engine.root!.completion - 0.45 / 0.95) < 1e-9)

        engine.settings.excluded = [:]
        engine.exclusionsChanged(at: epd, tree: tree, stats: stats.lookup)
        #expect(engine.root!.gapCount == 1)
    }

    @Test func repliesAtUnsavedPosition() throws {
        let (tree, stats) = fixture()
        var engine = CoverageEngine(settings: CoverageSettings(color: .white, targetGames: 10, minGames: 10))
        engine.recomputeAll(tree: tree, stats: stats.lookup)
        let epd = tree[tree.find("e4")!]!.epd
        engine.settings.excluded = [epd: ["c7c6"]]
        let replies = engine.replies(at: epd, stats: stats.lookup(epd)!, reach: 0.5)
        #expect(replies.map(\.san) == ["c5", "e5", "e6", "c6"])
        #expect(replies.map(\.required) == [true, true, false, false])
        #expect(abs(replies[1].reach - 0.15) < 1e-9)
        #expect(replies[3].excluded && replies.allSatisfy { $0.child == nil })
    }

    @Test func incrementalAddAndStatsArrival() throws {
        var (tree, stats) = fixture()
        var engine = CoverageEngine(settings: CoverageSettings(color: .white, targetGames: 10, minGames: 10))
        engine.recomputeAll(tree: tree, stats: stats.lookup)

        stats.set("e4 e5 Nf3", [("Nc6", 1000)])
        let e5nf3 = tree.find("e4 e5 Nf3")!
        engine.statsArrived(for: tree[e5nf3]!.epd, tree: tree, stats: stats.lookup)
        #expect(engine.root!.gapCount == 3)
        #expect(engine.root!.pendingCount == 0)

        stats.set("e4 e5 Nf3 Nc6 Bb5", [("a6", 5)])
        let leaf = tree.add("e4 e5 Nf3 Nc6 Bb5")
        engine.update(changedAt: e5nf3, epds: [tree[leaf]!.epd], tree: tree, stats: stats.lookup)
        #expect(abs(engine.root!.completion - 0.6 / 0.95) < 1e-9)
        #expect(engine.root!.gapCount == 2)
    }

    @Test func transpositionCountsAsCovered() throws {
        var tree = RepertoireTree()
        tree.add("d4 Nf6 c4 e6 Nc3")
        tree.add("d4 e6 c4 Nf6")
        var stats = FixtureStats()
        stats.set("d4", [("Nf6", 50), ("e6", 50)])
        stats.set("d4 Nf6 c4", [("e6", 100)])
        stats.set("d4 Nf6 c4 e6 Nc3", [("Bb4", 5)])
        stats.set("d4 e6 c4", [("Nf6", 100)])
        var engine = CoverageEngine(settings: CoverageSettings(color: .white, targetGames: 10, minGames: 10))
        engine.recomputeAll(tree: tree, stats: stats.lookup)
        let transposed = tree.find("d4 e6 c4 Nf6")!
        let canonical = tree.find("d4 Nf6 c4 e6")!
        #expect(engine[transposed]!.status == .transposition(canonical))
        #expect(engine.root!.gapCount == 0)
    }

    @Test func belowTargetLinesRequireNothing() throws {
        var tree = RepertoireTree()
        tree.add("e4 c6")
        var stats = FixtureStats()
        stats.set("e4", [("c5", 990), ("c6", 10)])
        var engine = CoverageEngine(settings: CoverageSettings(color: .white, targetGames: 50, minGames: 10))
        engine.recomputeAll(tree: tree, stats: stats.lookup)
        #expect(engine[tree.find("e4 c6")!]!.status == .belowTarget)
        #expect(engine.root!.gapCount == 1)  // c5 is missing
    }
}

/// Incremental results must equal a full recompute after any sequence of edits.
struct CoveragePropertyTests {
    struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 14695981039346656037
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }

    final class Cache: @unchecked Sendable { var stats: [EPD: ExplorerStats?] = [:] }
    static let cache = Cache()

    /// Synthetic stats: a few legal moves per position with hash-based counts.
    static func synthetic(_ epd: EPD, missing: Set<EPD>) -> ExplorerStats? {
        if missing.contains(epd) { return nil }
        if let cached = cache.stats[epd] { return cached }
        let value = makeSynthetic(epd)
        cache.stats[epd] = value
        return value
    }

    static func makeSynthetic(_ epd: EPD) -> ExplorerStats? {
        guard let pos = ChessPosition(fen: epd.queryFEN) else { return nil }
        let moves = pos.legalMoves().sorted { fnv(epd.rawValue + $0.uci) < fnv(epd.rawValue + $1.uci) }.prefix(4)
        let explorer = moves.enumerated().map { i, m in
            ExplorerMove(uci: m.uci, san: m.san, white: Int(fnv(m.uci + epd.rawValue) % 200) + (4 - i) * 100, draws: 0, black: 0)
        }
        let total = explorer.reduce(0) { $0 + $1.games }
        return ExplorerStats(white: total, draws: 0, black: 0, moves: Array(explorer))
    }

    @Test(.serialized, arguments: [Side.white, Side.black], [1, 2, 3])
    func incrementalEqualsFull(color: Side, seed: Int) throws {
        var rng = Rng(state: UInt64(seed))
        var tree = RepertoireTree()
        var missing: Set<EPD> = []
        let settings = CoverageSettings(color: color, targetGames: 40, minGames: 50)
        var engine = CoverageEngine(settings: settings)
        engine.recomputeAll(tree: tree, stats: { Self.synthetic($0, missing: missing) })

        for step in 0..<120 {
            let ids = Array(tree.nodes.keys).sorted()
            let target = ids[Int(rng.next() % UInt64(ids.count))]
            let action = rng.next() % 10
            if action < 7 {
                // add a move: prefer explorer moves so lines stay in the required region
                let node = tree[target]!
                let options = Self.synthetic(node.epd, missing: [])?.moves.map(\.uci) ?? []
                guard !options.isEmpty else { continue }
                let uci = options[Int(rng.next() % UInt64(options.count))]
                guard let added = tree.addMove(uci, after: target) else { continue }
                if rng.next() % 4 == 0 { missing.insert(tree[added]!.epd) }
                engine.update(changedAt: target, epds: [tree[added]!.epd], tree: tree, stats: { Self.synthetic($0, missing: missing) })
            } else if action == 7, (tree[target]?.ply ?? 0) >= 3 {
                let parent = tree[target]!.parent!
                let removed = Set(tree.subtree(of: target).compactMap { tree[$0]?.epd })
                tree.delete(target)
                engine.update(changedAt: parent, epds: removed, tree: tree, stats: { Self.synthetic($0, missing: missing) })
            } else if action == 8, target != RepertoireTree.rootID {
                let parent = tree[target]!.parent!
                let affected = Set(tree.subtree(of: parent).compactMap { tree[$0]?.epd })
                tree.promote(target)
                engine.update(changedAt: parent, epds: affected, tree: tree, stats: { Self.synthetic($0, missing: missing) })
            } else if let epd = missing.first {
                missing.remove(epd)
                engine.statsArrived(for: epd, tree: tree, stats: { Self.synthetic($0, missing: missing) })
            }

            var full = CoverageEngine(settings: settings)
            full.recomputeAll(tree: tree, stats: { Self.synthetic($0, missing: missing) })
            for id in tree.nodes.keys {
                let a = try #require(engine[id], "step \(step) node \(id) missing")
                let b = full[id]!
                #expect(a.status == b.status, "step \(step) node \(id)")
                #expect(abs(a.completion - b.completion) < 1e-9, "step \(step) node \(id)")
                #expect(a.gapCount == b.gapCount, "step \(step) node \(id)")
                #expect(a.pendingCount == b.pendingCount, "step \(step) node \(id)")
                if a.status != b.status || a.gapCount != b.gapCount { return }
            }
        }
        #expect(tree.count > 10)
    }
}
