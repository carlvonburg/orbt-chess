import Foundation
import Testing
@testable import OpeningCore

/// Writes the reference outputs the Rust core is diffed against into `core/fixtures/`.
/// Off by default; run `OT_WRITE_GOLDENS=1 swift test --filter GoldenFixtureTests`.
/// See `core/fixtures/README.md` for the files and their schemas.
@Suite(.serialized, .enabled(if: Golden.enabled))
struct GoldenFixtureTests {
    // MARK: Inputs

    static let parserEdgeCases = """
    [Event "Edge \\"quoted\\" \\\\ tag"]
    [Site "?"]
    [Result "1-0"]
    % escaped line, ignored
    { before } 1. e4!! $14 { after e4 } ( { pre variation } 1. d4?! d5 ( 1... Nf6 2. c4 g6 ) 2. c4 ) 1... e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. 0-0 Be7
    6. Re1 b5 7. Bb3 d6 8. c3 O-O 9. h3 ; rest of line
    Nb8 $2 $18 10. d4 Nbd7 11. Nbd2 Bb7 12. Bc2 Re8 13. Nf1 Bf8 14. Ng3 g6 15. a4 c5 16. d5 c4 17. Bg5 h6 18. Be3 Nc5 19. Qd2 h5 1-0

    1. d4 d5 2. c4 dxc4 3. e4 b5 4. a4 c6 5. axb5 cxb5 6. Qf3 Nc6 7. Qxf7+ Kd7 8. Qf5+ Ke8 9. Qh5+ g6 10. Qxb5 *
    [Event "No result token above"]

    1. e4 d5 2. exd5 Qxd5 3. Nc3 Qa5 4. d4 c6 5. Nf3 Bf5 6. Bc4 e6 7. Bd2 Nbd7 8. Qe2 Bb4 9. O-O-O Ngf6 10. Kb1 *

    [Event "Promotion"]
    [SetUp "1"]
    [FEN "8/4P3/8/8/8/8/k7/4K3 w - - 0 1"]

    1. e8=Q+ Kb2 *

    [Event "Black to move start"]
    [SetUp "1"]
    [FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"]

    1... c5 2. Nf3 *

    [Event "En passant and check"]

    1. e4 Nf6 2. e5 d5 3. exd6 cxd6 4. d4 Qa5+ 5. Bd2 Qb6 (5... Qd5 6. Nf3) *
    """

    static let inline: [(String, String)] = [
        ("sicilian_chapters", PGNTests.sample),
        ("writer_black_after_variation", "1. e4 e5 (1... c5) 2. Nf3 *"),
        ("writer_black_after_comment", "1. e4 {best} e5 *"),
        ("illegal_move", "1. e4 e5 2. Ke3 Nc6 (2... Nf6 3. Nc3) *"),
        ("nonstandard_start", "[Event \"Endgame\"]\n[SetUp \"1\"]\n[FEN \"8/8/8/4k3/8/8/4P3/4K3 w - - 0 1\"]\n\n1. Kd2 *"),
        ("chapters_ab", "[Event \"A\"]\n\n1. e4 e5 *\n\n[Event \"B\"]\n\n1. d4 d5 *"),
        ("note_commands", "1. e4 { [%cal Ge2e4] old } *"),
        ("merge_base", "1. e4 e5 2. Nf3 *"),
        ("transposition", TranspositionTests().pgn),
        ("transposition_chapters", "[Event \"A\"]\n\n1. d4 d5 2. c4 c6 3. Nf3 Nf6 4. Nc3 *\n\n[Event \"B\"]\n\n1. d4 d5 2. Nf3 Nf6 3. c4 c6 4. e3 *"),
        ("transposition_three_orders", "1. d4 d5 2. c4 (2. Nf3 Nf6 3. c4 c6 4. Nc3) (2. Bf4 Nf6 3. Nf3 c6 4. c4) c6 3. Nf3 Nf6 4. Nc3 *"),
        ("parser_edge_cases", parserEdgeCases),
    ]

    static let files: [(String, String)] = [
        ("berlin", "Berlin-2026-09-22T19_03_40.239Z.pgn"),
        ("semislav", "Semi-Slav-2026-09-22T18_59_03.655Z.pgn"),
    ]

    /// Every input PGN by fixture name. The large files must exist.
    static func inputs() throws -> [(String, String)] {
        var result = inline
        for (name, file) in files {
            let url = Golden.testData.appendingPathComponent(file)
            result.append((name, try String(contentsOf: url, encoding: .utf8)))
        }
        return result
    }

    static let sizeLimit = 20_000_000

    // MARK: PGN and tree

    @Test func pgnAndTrees() throws {
        var manifest: [String: J] = [:]
        for (name, text) in try Self.inputs() {
            try Golden.write(text, to: "inputs/\(name).pgn")
            let games = PGNParser.parse(text)
            let parsed: J = ["games": .array(games.map(J.pgnGame))]
            var parseSize = try Golden.write(parsed, to: "pgn/\(name).parse.json", pretty: text.count < 5_000)
            if parseSize > Self.sizeLimit {
                // Summary instead: per-game hash of the compact JSON.
                let summary: J = ["summary": true, "gameCount": .i(games.count),
                                  "gameHashes": .array(try games.map { .string(Golden.fnvHex(try Golden.compactJSON(J.pgnGame($0)))) })]
                parseSize = try Golden.write(summary, to: "pgn/\(name).parse.json")
            }
            try Golden.write(PGNWriter.write(games), to: "pgn/\(name).written.pgn")

            let tree = RepertoireTree(pgn: text)
            let treeSize = try Golden.write(J.tree(tree), to: "tree/\(name).tree.json", pretty: tree.count < 2000)
            try Golden.write(tree.pgnText(), to: "tree/\(name).pgn")
            manifest[name] = ["parseBytes": .i(parseSize), "treeBytes": .i(treeSize), "nodes": .i(tree.count)]
        }
        try Golden.write(.object(manifest), to: "tree/manifest.json")
    }

    /// Scripted edits: the tree after each step.
    @Test func treeEdits() throws {
        func snapshot(_ op: J, _ result: J, _ tree: RepertoireTree) -> J {
            ["op": op, "result": result, "tree": J.tree(tree), "pgnText": .string(tree.pgnText())]
        }
        var scenarios: [String: J] = [:]
        let root = RepertoireTree.rootID

        var t = RepertoireTree()
        var steps: [J] = [snapshot(["op": "new"], nil, t)]
        func step(_ op: J, _ result: NodeID?) { steps.append(snapshot(op, .i(result), t)) }
        let e4 = t.addMove("e2e4", after: root); step(["op": "addMove", "uci": "e2e4", "after": .i(root)], e4)
        step(["op": "addMoveSAN", "san": "e4", "after": .i(root)], t.addMove(san: "e4", after: root))
        let c5 = t.addMove(san: "c5", after: e4!); step(["op": "addMoveSAN", "san": "c5", "after": .i(e4!)], c5)
        let e5 = t.addMove(san: "e5", after: e4!); step(["op": "addMoveSAN", "san": "e5", "after": .i(e4!)], e5)
        t.promote(e5!); step(["op": "promote", "id": .i(e5!)], nil)
        let nf3 = t.addMove(san: "Nf3", after: c5!); step(["op": "addMoveSAN", "san": "Nf3", "after": .i(c5!)], nf3)
        t.delete(c5!); step(["op": "delete", "id": .i(c5!)], nil)
        let a = t.addLine(["d2d4", "g8f6", "c2c4", "e7e6"], after: root)
        step(["op": "addLine", "ucis": .strings(["d2d4", "g8f6", "c2c4", "e7e6"]), "after": .i(root)], a)
        let b = t.addLine(["c2c4", "e7e6", "d2d4", "g8f6"], after: root)
        step(["op": "addLine", "ucis": .strings(["c2c4", "e7e6", "d2d4", "g8f6"]), "after": .i(root)], b)
        let nf3b = t.addMove(san: "Nf3", after: e5!); step(["op": "addMoveSAN", "san": "Nf3", "after": .i(e5!)], nf3b)
        let nc6 = t.addMove(san: "Nc6", after: nf3b!); step(["op": "addMoveSAN", "san": "Nc6", "after": .i(nf3b!)], nc6)
        let bb5 = t.addMove(san: "Bb5!?", after: nc6!); step(["op": "addMoveSAN", "san": "Bb5!?", "after": .i(nc6!)], bb5)
        step(["op": "addMoveSAN", "san": "Ke3", "after": .i(nc6!)], t.addMove(san: "Ke3", after: nc6!))
        step(["op": "addMove", "uci": "e1h1", "after": .i(nc6!)], t.addMove("e1h1", after: nc6!))
        t.setNote("  new idea  ", for: e4!); step(["op": "setNote", "text": "  new idea  ", "id": .i(e4!)], nil)
        t.setChapterTag(0, "Event", "Edited"); step(["op": "setChapterTag", "index": 0, "name": "Event", "value": "Edited"], nil)
        t.setChapterTag(0, "White", "Me"); step(["op": "setChapterTag", "index": 0, "name": "White", "value": "Me"], nil)
        let merged = t.merge(PGNParser.parse("1... c5 2. Nf3 (2. c3 d5) d6 *")[0].moves, at: e4!)
        steps.append(snapshot(["op": "mergeMoves", "pgn": "1... c5 2. Nf3 (2. c3 d5) d6 *", "at": .i(e4!)], .i(merged), t))
        scenarios["edits"] = .array(steps)

        var chapters = RepertoireTree(pgn: "[Event \"A\"]\n\n1. e4 e5 *\n\n[Event \"B\"]\n\n1. d4 d5 *")
        steps = [snapshot(["op": "parse", "pgn": "chapters_ab"], nil, chapters)]
        let d4 = chapters.child(of: root, san: "d4")!
        let d5 = chapters.child(of: d4, san: "d5")!
        let c4 = chapters.addMove(san: "c4", after: d5)
        steps.append(snapshot(["op": "addMoveSAN", "san": "c4", "after": .i(d5)], .i(c4), chapters))
        scenarios["chapters"] = .array(steps)

        var notes = RepertoireTree(pgn: "1. e4 { [%cal Ge2e4] old } *")
        let ne4 = notes.child(of: root, san: "e4")!
        steps = [snapshot(["op": "parse", "pgn": "note_commands"], nil, notes)]
        notes.setNote("new idea", for: ne4)
        steps.append(snapshot(["op": "setNote", "text": "new idea", "id": .i(ne4)], nil, notes))
        notes.setNote("", for: ne4)
        steps.append(snapshot(["op": "setNote", "text": "", "id": .i(ne4)], nil, notes))
        scenarios["notes"] = .array(steps)

        var local = RepertoireTree(pgn: "1. e4 e5 2. Nf3 *")
        local.add("e4 c5 Nf3")
        var remote = RepertoireTree(pgn: "1. e4 e5 2. Nf3 *")
        remote.add("e4 e6 d4")
        let localBefore = J.tree(local), remoteTree = J.tree(remote)
        let added = local.merge(tree: remote)
        scenarios["mergeTree"] = ["local": localBefore, "remote": remoteTree, "added": .i(added), "result": J.tree(local),
                                  "pgnText": .string(local.pgnText())]
        try Golden.write(.object(scenarios), to: "tree/edits.json")
    }

    // MARK: Coverage

    static func synthetic(_ epd: EPD) -> ExplorerStats? { CoveragePropertyTests.makeSynthetic(epd) }

    /// LargeRepertoireTests' worst case: stats for every position, from the tree's moves.
    /// Transposed positions take the stats of their lowest node id.
    static func treeStats(_ tree: RepertoireTree) -> [EPD: ExplorerStats] {
        var stats: [EPD: ExplorerStats] = [:]
        for id in tree.nodes.keys.sorted() {
            let node = tree[id]!
            guard stats[node.epd] == nil else { continue }
            let moves = node.children.compactMap { tree[$0]?.move }.enumerated().map { i, m in
                ExplorerMove(uci: m.uci, san: m.san, white: 1000 / (i + 1), draws: 0, black: 0)
            }
            let total = moves.reduce(0) { $0 + $1.games } + 200
            stats[node.epd] = ExplorerStats(white: total, draws: 0, black: 0, moves: moves)
        }
        return stats
    }

    static func coverageJ(tree: RepertoireTree, settings: CoverageSettings, scheme: String,
                          source: @escaping (EPD) -> ExplorerStats?) -> (J, CoverageEngine) {
        let recorder = StatsRecorder(source)
        var engine = CoverageEngine(settings: settings)
        engine.recomputeAll(tree: tree, stats: recorder.lookup)
        var out = J.engine(engine, tree: tree)
        if case .object(var o) = out {
            o["settings"] = J.settings(settings)
            o["scheme"] = .string(scheme)
            o["stats"] = recorder.json
            out = .object(o)
        }
        return (out, engine)
    }

    @Test func coverage() throws {
        var manifest: [String: J] = [:]
        for (name, text) in try Self.inputs() {
            let tree = RepertoireTree(pgn: text)
            let stats = Self.treeStats(tree)
            let schemes: [(String, Int, Int, (EPD) -> ExplorerStats?)] = [
                ("synthetic", 40, 50, { Self.synthetic($0) }),
                ("synthetic_missing", 40, 50, { Golden.fnv($0.rawValue) % 5 == 0 ? nil : Self.synthetic($0) }),
                ("treestats", 500, 25, { stats[$0] }),
                ("treestats_missing", 500, 25, { Golden.fnv($0.rawValue) % 5 == 0 ? nil : stats[$0] }),
            ]
            for (scheme, target, minGames, source) in schemes {
                for color in Side.allCases {
                    let settings = CoverageSettings(color: color, targetGames: target, minGames: minGames)
                    let (json, engine) = Self.coverageJ(tree: tree, settings: settings, scheme: scheme, source: source)
                    let path = "coverage/\(name).\(scheme).\(color.rawValue).json"
                    var size = try Golden.write(json, to: path, pretty: tree.count < 2000)
                    if size > Self.sizeLimit {
                        let hashes = try engine.info.keys.sorted().map { id -> (String, J) in
                            (String(id), .string(Golden.fnvHex(try Golden.compactJSON(J.coverage(engine[id]!)))))
                        }
                        let summary: J = ["summary": true, "settings": J.settings(settings), "scheme": .string(scheme),
                                          "root": engine.root.map(J.coverage) ?? .null,
                                          "gaps": .array(engine.gaps().map { J.gap($0) }),
                                          "nodeHashes": .object(Dictionary(uniqueKeysWithValues: hashes))]
                        size = try Golden.write(summary, to: path)
                    }
                    manifest["\(name).\(scheme).\(color.rawValue)"] = .i(size)
                }
            }
        }
        try Golden.write(.object(manifest), to: "coverage/manifest.json")
    }

    /// CoverageTests' and TranspositionTests' hand-made fixtures.
    @Test func coverageHand() throws {
        var out: [String: J] = [:]
        func record(_ name: String, _ tree: RepertoireTree, _ settings: CoverageSettings, _ stats: FixtureStats) {
            let (json, _) = Self.coverageJ(tree: tree, settings: settings, scheme: "fixture", source: stats.lookup)
            out[name] = ["tree": J.tree(tree), "pgnText": .string(tree.pgnText()), "coverage": json]
        }
        let (tree, stats) = CoverageTests().fixture()
        let s10 = CoverageSettings(color: .white, targetGames: 10, minGames: 10)
        record("fixture", tree, s10, stats)
        let e4epd = tree[tree.find("e4")!]!.epd
        var excluded = s10
        excluded.excluded = [e4epd: ["e7e6"]]
        record("fixture_excluded", tree, excluded, stats)
        var t2 = tree
        var stats2 = stats
        t2.add("e4 e6 d4")
        stats2.set("e4 e6 d4", [("d5", 5)])
        record("fixture_excluded_saved_anyway", t2, excluded, stats2)

        var engine = CoverageEngine(settings: s10)
        engine.recomputeAll(tree: tree, stats: stats.lookup)
        engine.settings.excluded = [e4epd: ["c7c6"]]
        let replies = engine.replies(at: e4epd, stats: stats.lookup(e4epd)!, reach: 0.5)
        out["replies_at_unsaved"] = ["epd": .string(e4epd.rawValue), "reach": .double(0.5), "settings": J.settings(engine.settings),
                                     "stats": J.stats(stats.lookup(e4epd)), "replies": .array(replies.map(J.reply))]

        var tr = RepertoireTree()
        tr.add("d4 Nf6 c4 e6 Nc3")
        tr.add("d4 e6 c4 Nf6")
        var trStats = FixtureStats()
        trStats.set("d4", [("Nf6", 50), ("e6", 50)])
        trStats.set("d4 Nf6 c4", [("e6", 100)])
        trStats.set("d4 Nf6 c4 e6 Nc3", [("Bb4", 5)])
        trStats.set("d4 e6 c4", [("Nf6", 100)])
        record("transposition_covered", tr, s10, trStats)

        var below = RepertoireTree()
        below.add("e4 c6")
        var belowStats = FixtureStats()
        belowStats.set("e4", [("c5", 990), ("c6", 10)])
        record("below_target", below, CoverageSettings(color: .white, targetGames: 50, minGames: 10), belowStats)

        let leafTree = RepertoireTree(pgn: TranspositionTests().pgn)
        var leafStats = FixtureStats()
        leafStats.set("", [("d4", 100)])
        leafStats.set("d4 d5", [("c4", 50), ("Nf3", 50)])
        leafStats.set("d4 d5 Nf3 Nf6", [("c4", 100)])
        record("opponent_to_move_leaf", leafTree, CoverageSettings(color: .black, targetGames: 10, minGames: 1), leafStats)
        try Golden.write(.object(out), to: "coverage/hand.json")
    }

    /// CoveragePropertyTests' random edits, recorded as operations with the engine state after
    /// each. Deviation from the property test: stats arrive for `missing.min()` instead of
    /// `missing.first` (a Set's first element changes between runs).
    @Test(arguments: [Side.white, Side.black], [1, 2, 3])
    func coverageIncremental(color: Side, seed: Int) throws {
        var rng = CoveragePropertyTests.Rng(state: UInt64(seed))
        var tree = RepertoireTree()
        var missing: Set<EPD> = []
        let settings = CoverageSettings(color: color, targetGames: 40, minGames: 50)
        var engine = CoverageEngine(settings: settings)
        engine.recomputeAll(tree: tree, stats: { missing.contains($0) ? nil : Self.synthetic($0) })
        var ops: [J] = []
        for step in 0..<120 {
            let ids = Array(tree.nodes.keys).sorted()
            let target = ids[Int(rng.next() % UInt64(ids.count))]
            let action = rng.next() % 10
            var op: [String: J] = ["step": .i(step)]
            if action < 7 {
                let node = tree[target]!
                let options = Self.synthetic(node.epd)?.moves.map(\.uci) ?? []
                guard !options.isEmpty else { continue }
                let uci = options[Int(rng.next() % UInt64(options.count))]
                guard let added = tree.addMove(uci, after: target) else { continue }
                let miss = rng.next() % 4 == 0
                if miss { missing.insert(tree[added]!.epd) }
                engine.update(changedAt: target, epds: [tree[added]!.epd], tree: tree, stats: { missing.contains($0) ? nil : Self.synthetic($0) })
                op.merge(["op": "addMove", "after": .i(target), "uci": .string(uci), "added": .i(added),
                          "missingInserted": .bool(miss), "updateEPDs": .strings([tree[added]!.epd.rawValue])]) { $1 }
            } else if action == 7, (tree[target]?.ply ?? 0) >= 3 {
                let parent = tree[target]!.parent!
                let removed = Set(tree.subtree(of: target).compactMap { tree[$0]?.epd })
                tree.delete(target)
                engine.update(changedAt: parent, epds: removed, tree: tree, stats: { missing.contains($0) ? nil : Self.synthetic($0) })
                op.merge(["op": "delete", "id": .i(target), "changedAt": .i(parent),
                          "updateEPDs": .strings(removed.map(\.rawValue).sorted())]) { $1 }
            } else if action == 8, target != RepertoireTree.rootID {
                let parent = tree[target]!.parent!
                let affected = Set(tree.subtree(of: parent).compactMap { tree[$0]?.epd })
                tree.promote(target)
                engine.update(changedAt: parent, epds: affected, tree: tree, stats: { missing.contains($0) ? nil : Self.synthetic($0) })
                op.merge(["op": "promote", "id": .i(target), "changedAt": .i(parent),
                          "updateEPDs": .strings(affected.map(\.rawValue).sorted())]) { $1 }
            } else if let epd = missing.min() {
                missing.remove(epd)
                let changed = engine.statsArrived(for: epd, tree: tree, stats: { missing.contains($0) ? nil : Self.synthetic($0) })
                op.merge(["op": "statsArrived", "epd": .string(epd.rawValue), "changed": .bool(changed)]) { $1 }
            } else {
                continue
            }
            op["root"] = engine.root.map(J.coverage) ?? .null
            op["missing"] = .strings(missing.map(\.rawValue).sorted())
            ops.append(.object(op))
        }
        var full = CoverageEngine(settings: settings)
        let recorder = StatsRecorder { missing.contains($0) ? nil : Self.synthetic($0) }
        full.recomputeAll(tree: tree, stats: recorder.lookup)
        let out: J = ["settings": J.settings(settings), "seed": .i(seed), "ops": .array(ops),
                      "finalTree": J.tree(tree), "final": J.engine(engine, tree: tree),
                      "finalFull": J.engine(full, tree: tree), "finalStats": recorder.json]
        try Golden.write(out, to: "coverage/incremental.\(color.rawValue).\(seed).json")
    }

    // MARK: Scheduler

    static let t0: Int64 = 1_700_000_000

    /// Day `d` ends (rolls over) at `t0 + (d + 1) days`.
    static func timing(day: Int, secondsIntoDay: Int64) -> SchedTiming {
        let next = t0 + Int64(day + 1) * 86_400
        return SchedTiming(daysElapsed: day, nextDayAt: next, now: next - 86_400 + secondsIntoDay)
    }

    static func timing(at now: Int64) -> SchedTiming {
        let day = Int((now - t0) / 86_400)
        return SchedTiming(daysElapsed: day, nextDayAt: t0 + Int64(day + 1) * 86_400, now: now)
    }

    struct Scenario {
        var name: String
        var config = DeckConfig()
        var epd: EPD
        var start: Card?
        var position = 0
        var ratings: [Rating]
        var startTiming: SchedTiming
        /// Days late for a review or day-learn step (negative: early, which is answered filtered).
        var daysLate = 0
        /// Extra seconds after a learning step's due.
        var learnDelay: Int64 = 0
        var filtered = false
    }

    static func runScenario(_ s: Scenario, revlog: inout [RevlogEntry]) -> J {
        let scheduler = Scheduler(config: s.config)
        var card = s.start
        var timing = s.startTiming
        var steps: [J] = []
        for (i, rating) in s.ratings.enumerated() {
            let filtered = s.filtered || s.daysLate < 0 && card?.queue == .review
            let id = card?.id ?? Card.id(for: s.epd)
            let next = scheduler.nextStates(card, id: id, position: s.position, timing: timing, filtered: filtered)
            let taken = i == 3 ? 75_000 : 4_000 + i * 1_000
            let answer = scheduler.answer(card, epd: s.epd, position: s.position, rating: rating, timing: timing,
                                          filtered: filtered, takenMillis: taken)
            revlog.append(answer.revlog)
            steps.append(["timing": J.timing(timing), "rating": .i(rating.rawValue), "filtered": .bool(filtered),
                          "takenMillis": .i(taken), "position": .i(s.position), "before": J.card(card),
                          "nextStates": J.states(next), "card": J.card(answer.card), "revlog": .raw(answer.revlog),
                          "fromQueue": .i(answer.fromQueue.rawValue), "leeched": .bool(answer.leeched)])
            card = answer.card
            let c = answer.card
            switch c.queue {
            case .learn:
                timing = Self.timing(at: max(c.due + s.learnDelay, timing.now + 1))
            default:
                timing = Self.timing(day: Int(c.due) + s.daysLate, secondsIntoDay: 8 * 3600 + Int64(i) * 61)
            }
        }
        return ["name": .string(s.name), "config": J.config(s.config), "epd": .string(s.epd.rawValue),
                "cardID": .i(Card.id(for: s.epd)), "start": J.card(s.start), "steps": .array(steps)]
    }

    static func epd(_ line: String) -> EPD {
        var p = ChessPosition.start
        for san in line.split(separator: " ") { p = p.play(san: String(san))!.1 }
        return p.epd
    }

    static func reviewCard(epd: EPD, interval: Int, due: Int, lapses: Int = 0, memory: MemoryState?, lastReview: Int64?) -> Card {
        var c = Card(id: Card.id(for: epd), position: 0, added: t0)
        c.ctype = .review
        c.queue = .review
        c.interval = interval
        c.due = Int64(due)
        c.easeFactor = 2500
        c.reps = 5
        c.lapses = lapses
        c.memory = memory
        c.lastReviewTime = lastReview
        c.originalPosition = 0
        return c
    }

    @Test func scheduler() throws {
        let G = Rating.good, A = Rating.again
        let start = Self.timing(day: 100, secondsIntoDay: 8 * 3600)
        let lines = ["", "e4", "d4", "e4 e5", "e4 c5", "d4 d5 c4", "c4", "Nf3", "e4 e5 Nf3 Nc6 Bb5", "d4 Nf6 c4 e6 Nc3 Bb4"]
        var scenarios: [Scenario] = []
        for line in lines {
            let e = Self.epd(line)
            let tag = line.isEmpty ? "start" : line.replacingOccurrences(of: " ", with: "_")
            scenarios.append(Scenario(name: "new_good_chain.\(tag)", epd: e, ratings: Array(repeating: G, count: 10), startTiming: start))
            scenarios.append(Scenario(name: "new_again_good.\(tag)", epd: e, position: 7, ratings: [A, G, A, G, G, G, A, G, G, G], startTiming: start))
            scenarios.append(Scenario(name: "new_mixed_late.\(tag)", epd: e, ratings: [G, A, G, G, A, A, G, G, G, G],
                                      startTiming: start, daysLate: 2, learnDelay: 90))
        }
        let e4 = Self.epd("e4")
        let lastReview = start.now - 10 * 86_400
        scenarios.append(Scenario(name: "review_on_time", epd: e4,
                                  start: Self.reviewCard(epd: e4, interval: 10, due: 100, memory: MemoryState(stability: 10, difficulty: 5), lastReview: lastReview),
                                  ratings: [G, G, A, G, G, G], startTiming: start))
        scenarios.append(Scenario(name: "review_late", epd: e4,
                                  start: Self.reviewCard(epd: e4, interval: 10, due: 97, memory: MemoryState(stability: 10, difficulty: 5), lastReview: lastReview - 3 * 86_400),
                                  ratings: [G, G, A, G, G], startTiming: start, daysLate: 3))
        scenarios.append(Scenario(name: "review_early_filtered", epd: e4,
                                  start: Self.reviewCard(epd: e4, interval: 10, due: 105, memory: MemoryState(stability: 10, difficulty: 5), lastReview: start.now - 5 * 86_400),
                                  ratings: [G, G, G, A, G], startTiming: start, daysLate: -2))
        scenarios.append(Scenario(name: "review_filtered_session", epd: e4,
                                  start: Self.reviewCard(epd: e4, interval: 30, due: 120, memory: MemoryState(stability: 30, difficulty: 3), lastReview: start.now - 10 * 86_400),
                                  ratings: [G, A, G, G], startTiming: start, filtered: true))
        scenarios.append(Scenario(name: "review_no_memory", epd: e4,
                                  start: Self.reviewCard(epd: e4, interval: 4, due: 100, memory: nil, lastReview: nil),
                                  ratings: [G, A, G, G], startTiming: start))
        var relearn = Self.reviewCard(epd: e4, interval: 3, due: 0, lapses: 2, memory: MemoryState(stability: 1.5, difficulty: 7), lastReview: start.now - 700)
        relearn.ctype = .relearn
        relearn.queue = .learn
        relearn.remainingSteps = 1
        relearn.due = start.now - 100
        scenarios.append(Scenario(name: "relearn", epd: e4, start: relearn, ratings: [G, A, G, G, A, G], startTiming: start))
        var leech = Self.reviewCard(epd: e4, interval: 1, due: 100, lapses: 7, memory: MemoryState(stability: 1, difficulty: 9), lastReview: start.now - 86_400)
        scenarios.append(Scenario(name: "leech_tag_only", epd: e4, start: leech, ratings: [A, G, A, G], startTiming: start))
        var suspend = DeckConfig()
        suspend.leechAction = .suspend
        scenarios.append(Scenario(name: "leech_suspend", config: suspend, epd: e4, start: leech, ratings: [A], startTiming: start))
        leech.lapses = 15
        scenarios.append(Scenario(name: "leech_threshold_16", epd: e4, start: leech, ratings: [A, G], startTiming: start))
        scenarios.append(Scenario(name: "step_across_rollover", epd: e4, ratings: [G, G, G, A, G],
                                  startTiming: Self.timing(day: 100, secondsIntoDay: 86_400 - 300)))
        scenarios.append(Scenario(name: "again_near_rollover", epd: e4, ratings: [A, A, G, G],
                                  startTiming: Self.timing(day: 100, secondsIntoDay: 86_400 - 30)))
        var dayLearn = Card(id: Card.id(for: e4), position: 2, added: Self.t0)
        dayLearn.ctype = .learn
        dayLearn.queue = .dayLearn
        dayLearn.due = 99
        dayLearn.remainingSteps = 1
        dayLearn.reps = 1
        dayLearn.memory = MemoryState(stability: 2.3065, difficulty: 2.1)
        dayLearn.lastReviewTime = start.now - 2 * 86_400
        scenarios.append(Scenario(name: "day_learn", epd: e4, start: dayLearn, position: 2, ratings: [G, G, A, G], startTiming: start))

        var threeSteps = DeckConfig()
        threeSteps.learnSteps = [1, 10, 100]
        threeSteps.relearnSteps = []
        scenarios.append(Scenario(name: "three_steps_no_relearn", config: threeSteps, epd: e4, ratings: [G, G, G, G, A, G, G], startTiming: start))
        scenarios.append(Scenario(name: "three_steps_again", config: threeSteps, epd: e4, ratings: [A, G, A, G, G, G], startTiming: start))
        var noSteps = DeckConfig()
        noSteps.learnSteps = []
        noSteps.relearnSteps = []
        scenarios.append(Scenario(name: "no_steps", config: noSteps, epd: e4, ratings: [G, A, G, A, G], startTiming: start))
        var shortTerm = noSteps
        shortTerm.fsrsShortTermWithStepsEnabled = true
        scenarios.append(Scenario(name: "no_steps_short_term", config: shortTerm, epd: e4, ratings: [A, G, A, G, G], startTiming: start))
        var withSteps = DeckConfig()
        withSteps.fsrsShortTermWithStepsEnabled = true
        scenarios.append(Scenario(name: "short_term_with_steps", config: withSteps, epd: e4, ratings: [A, G, G, A, G], startTiming: start))
        var custom = DeckConfig()
        custom.desiredRetention = 0.8
        custom.maximumReviewInterval = 30
        custom.graduatingIntervalGood = 3
        custom.minimumLapseInterval = 2
        custom.capAnswerTimeToSecs = 20
        scenarios.append(Scenario(name: "retention_80_max_30", config: custom, epd: e4, ratings: Array(repeating: G, count: 9) + [A, G, G], startTiming: start))
        var high = DeckConfig()
        high.desiredRetention = 0.97
        scenarios.append(Scenario(name: "retention_97", config: high, epd: e4, ratings: [G, G, G, A, G, G, G], startTiming: start))

        var revlog: [RevlogEntry] = []
        let out = scenarios.map { Self.runScenario($0, revlog: &revlog) }
        try Golden.write(["t0": .i(Self.t0), "scenarios": .array(out)], to: "scheduler/answers.json")
        try Golden.write(RevlogFile.encode(revlog), to: "misc/scheduler.otlog.jsonl")
    }

    @Test func fuzzAndFSRS() throws {
        let seeds: [UInt64] = [0, 1, 2, 3, 42, 1000, 0x7FFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF,
                               UInt64(bitPattern: Card.id(for: ChessPosition.start.epd)), UInt64(bitPattern: Card.id(for: Self.epd("e4"))) &+ 3]
        let factors: [J] = seeds.map { ["seed": .string(String($0)), "factor": .d(fuzzFactor(seed: $0))] }
        var learning: [J] = []
        for seed in seeds {
            for secs in [0, 1, 3, 4, 59, 60, 330, 600, 1200, 3600, 6000, 86_400] {
                learning.append(["seed": .string(String(seed)), "secs": .i(secs), "result": .i(learningIntervalWithFuzz(seed: seed, secs))])
            }
        }
        var review: [J] = []
        for interval in [0.1, 1, 1.5, 2.49, 2.5, 3.3, 6.9, 7, 7.1, 12.4, 17, 19.9, 20, 20.1, 37, 100, 365.25, 1000, 40_000] {
            for (minimum, maximum) in [(1, 36500), (2, 36500), (3, 1000), (101, 1000), (1, 99), (97, 103), (3, 2)] {
                var row: [String: J] = ["interval": .double(interval), "minimum": .i(minimum), "maximum": .i(maximum)]
                let (lo, hi) = constrainedFuzzBounds(interval, minimum: minimum, maximum: maximum)
                row["bounds"] = [.i(lo), .i(hi)]
                row["noFuzz"] = .i(withReviewFuzz(nil, interval, minimum: minimum, maximum: maximum))
                row["fuzz"] = .array([0, 0.25, 0.5, 0.75, 0.99].map { f in ["factor": .double(f), "result": .i(withReviewFuzz(f, interval, minimum: minimum, maximum: maximum))] })
                review.append(.object(row))
            }
            for previous in [0, 1, 4, 5, 10, 50] {
                review.append(["interval": .double(interval), "previous": .i(previous), "maximum": 36500,
                               "minimumReviewFuzzInterval": .i(minimumReviewFuzzInterval(interval, previous: previous, maximum: 36500))])
            }
        }
        let fuzzSeeds: [J] = [(Int64(1), 0), (Int64(1), 5), (Card.id(for: ChessPosition.start.epd), 0), (Card.id(for: ChessPosition.start.epd), 7), (Int64.max, 1)]
            .map { ["cardID": .i($0.0), "reps": .i($0.1), "seed": .string(String(fuzzSeed(cardID: $0.0, reps: $0.1)))] }

        let fsrs = FSRS6()
        var fsrsRows: [J] = []
        let memories: [MemoryState?] = [nil, MemoryState(stability: 0.212, difficulty: 6.4133), MemoryState(stability: 1, difficulty: 5),
                                        MemoryState(stability: 10, difficulty: 5), MemoryState(stability: 100, difficulty: 9),
                                        MemoryState(stability: 0.5, difficulty: 1), MemoryState(stability: 40_000, difficulty: 11)]
        for m in memories {
            for retention in [0.7, 0.8, 0.9, 0.95, 0.99] {
                for days in [0, 1, 3, 10, 30, 365] {
                    let n = fsrs.nextStates(m, desiredRetention: retention, daysElapsed: days)
                    func item(_ s: FSRS6.ItemState) -> J { ["memory": J.memory(s.memory), "interval": .double(s.interval)] }
                    fsrsRows.append(["memory": J.memory(m), "desiredRetention": .double(retention), "daysElapsed": .i(days),
                                     "again": item(n.again), "hard": item(n.hard), "good": item(n.good), "easy": item(n.easy)])
                }
            }
        }
        var retrievability: [J] = []
        for s in [0.1, 1, 2.3065, 10, 100] {
            for t in [0.0, 0.5, 1, 5, 30, 365] {
                retrievability.append(["stability": .double(s), "days": .double(t), "r": .double(fsrs.retrievability(daysElapsed: t, stability: s))])
            }
        }
        var steps: [J] = []
        for list in [[1.0, 10], [10], [1, 10, 100], [], [1440], [4320], [0.5, 1, 2, 3]] {
            let ls = LearningSteps(list)
            for remaining in [0, 1, 2, 3, 4, 1001, 1002] {
                steps.append(["steps": .array(list.map { .double($0) }), "remaining": .i(remaining),
                              "again": .i(ls.againDelaySecsLearn()), "hard": .i(ls.hardDelaySecs(remaining)),
                              "good": .i(ls.goodDelaySecs(remaining)), "current": .i(ls.currentDelaySecs(remaining)),
                              "remainingForGood": .i(ls.remainingForGood(remaining)), "remainingForFailed": .i(ls.remainingForFailed())])
            }
        }
        var intervalKinds: [J] = []
        for k in [IntervalKind.secs(0), .secs(59), .secs(600), .secs(86_399), .secs(86_400), .secs(200_000), .days(3)] {
            for rollover in [0, 300, 600, 3600, 86_400] {
                let converted = k.maybeAsDays(secsUntilRollover: rollover)
                intervalKinds.append(["kind": J.interval(k), "secsUntilRollover": .i(rollover), "converted": J.interval(converted),
                                      "revlog": .i(converted.asRevlogInterval)])
            }
        }
        let leech: [J] = [(0, 8), (7, 8), (8, 8), (12, 8), (16, 8), (20, 8), (3, 3), (5, 3), (1, 1), (2, 1), (0, 0), (4, 0)]
            .map { ["lapses": .i($0.0), "threshold": .i($0.1), "met": .bool(leechThresholdMet(lapses: $0.0, threshold: $0.1))] }
        try Golden.write(["fuzzFactor": .array(factors), "learningIntervalWithFuzz": .array(learning), "review": .array(review),
                          "fuzzSeed": .array(fuzzSeeds), "fsrsNextStates": .array(fsrsRows), "retrievability": .array(retrievability),
                          "learningSteps": .array(steps), "intervalKind": .array(intervalKinds), "leechThreshold": .array(leech)],
                         to: "scheduler/vectors.json")
    }

    // MARK: Queues, trainer and sessions

    static func berlin() throws -> RepertoireTree {
        RepertoireTree(pgn: try String(contentsOf: Golden.testData.appendingPathComponent(files[0].1), encoding: .utf8))
    }

    static func semiSlav() throws -> RepertoireTree {
        RepertoireTree(pgn: try String(contentsOf: Golden.testData.appendingPathComponent(files[1].1), encoding: .utf8))
    }

    static func whiteTree() -> RepertoireTree { TrainingTests().whiteTree() }

    static func takeBackTree() -> RepertoireTree {
        var tree = RepertoireTree()
        tree.add("e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6 Be3")
        tree.add("e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6 Be3")
        tree.add("e4 e5 Nf3")
        tree.add("e4 e5 Bc4 Nf6 d3")
        tree.add("d4 d5 c4 e6 Nc3")
        tree.add("d4 Nf6 c4 e6 Nc3")
        return tree
    }

    /// Repertoires for trainer and session fixtures: (name, tree, color).
    static func trainingTrees() throws -> [(String, RepertoireTree, Side)] {
        [("white_tree", whiteTree(), .white),
         ("takeback_tree", takeBackTree(), .white),
         ("transposition", RepertoireTree(pgn: TranspositionTests().pgn), .black),
         ("transposition_three_orders", RepertoireTree(pgn: inline.first { $0.0 == "transposition_three_orders" }!.1), .black),
         ("berlin", try berlin(), .black),
         ("semislav", try semiSlav(), .black)]
    }

    /// Reach from the coverage engine under the tree stats, for the tree's color.
    static func reach(_ tree: RepertoireTree, color: Side) -> [NodeID: Double] {
        let stats = treeStats(tree)
        var engine = CoverageEngine(settings: CoverageSettings(color: color, targetGames: 500, minGames: 25))
        engine.recomputeAll(tree: tree, stats: { stats[$0] })
        return engine.info.compactMapValues(\.reach)
    }

    /// A deterministic card set over the trainer's card positions, by new-card index and hash.
    static func mixedCards(_ trainer: Trainer, order: [EPD], timing: SchedTiming) -> [EPD: Card] {
        var cards: [EPD: Card] = [:]
        let now = timing.now, today = timing.daysElapsed
        for (i, epd) in order.enumerated() {
            var c = Card(id: Card.id(for: epd), position: i, added: Self.t0)
            c.originalPosition = i
            c.easeFactor = 2500
            switch Golden.fnv(epd.rawValue) % 10 {
            case 0...3:
                continue
            case 4:
                c.ctype = .learn; c.queue = .learn; c.due = now - 50 - Int64(i); c.reps = 1; c.remainingSteps = 1
                c.memory = MemoryState(stability: 0.5, difficulty: 6); c.lastReviewTime = c.due - 600
            case 5:
                c.ctype = .learn; c.queue = .learn; c.due = now + 120 + Int64(37 * i % 50_000); c.reps = 2; c.remainingSteps = 1
                c.memory = MemoryState(stability: 1.2, difficulty: 5.5); c.lastReviewTime = now - 60
            case 6:
                let interval = 3 + i % 20
                c.ctype = .review; c.queue = .review; c.due = Int64(today - i % 4); c.interval = interval; c.reps = 3
                c.memory = MemoryState(stability: Double(interval), difficulty: 5 + Double(i % 4))
                c.lastReviewTime = now - Int64(interval + i % 4) * 86_400
            case 7:
                let interval = 5 + i % 30
                c.ctype = .review; c.queue = .review; c.due = Int64(today + 1 + i % 9); c.interval = interval; c.reps = 4
                c.memory = MemoryState(stability: Double(interval), difficulty: 4)
                c.lastReviewTime = now - Int64(interval - 1 - i % 9) * 86_400
            case 8:
                c.ctype = .learn; c.queue = .dayLearn; c.due = Int64(today - i % 2); c.reps = 1; c.remainingSteps = 1
                c.memory = MemoryState(stability: 2.3, difficulty: 3); c.lastReviewTime = now - Int64(1 + i % 2) * 86_400
            default:
                c.ctype = .relearn; c.interval = 4; c.lapses = 1; c.reps = 6; c.remainingSteps = 1
                c.memory = MemoryState(stability: 1.1, difficulty: 7); c.lastReviewTime = now - 300
                if i % 2 == 1 {
                    c.queue = .suspended; c.due = now - 1000
                } else {
                    c.queue = .learn; c.due = now + 413 + Int64(37 * i % 50_000)
                }
            }
            cards[epd] = c
        }
        return cards
    }

    @Test func trainer() throws {
        for (name, tree, color) in try Self.trainingTrees() {
            let trainer = Trainer(tree: tree, color: color)
            let reach = Self.reach(tree, color: color)
            let root = RepertoireTree.rootID
            let cardNodes = trainer.cardNodes()
            let lines = trainer.allLines(under: root)
            let branches = (tree[root]?.children ?? []).flatMap { c in [c] + (tree[c]?.children.prefix(2) ?? []) }
            let order = trainer.newCardOrder(reach: reach)
            let timing = Self.timing(day: 100, secondsIntoDay: 8 * 3600)
            let cards = Self.mixedCards(trainer, order: order, timing: timing)
            func progress(_ p: Trainer.Progress) -> J {
                ["cards": .i(p.cards), "learning": .i(p.learning), "young": .i(p.young), "mature": .i(p.mature), "suspended": .i(p.suspended)]
            }
            let out: J = [
                "color": .string(color.rawValue),
                "tree": J.tree(tree),
                "reach": .object(Dictionary(uniqueKeysWithValues: reach.map { (String($0.key), J.double($0.value)) })),
                "trainable": .ints(trainer.trainable.sorted()),
                "cardNodes": .ints(cardNodes),
                "cardEPDs": .strings(trainer.cardEPDSet.map(\.rawValue).sorted()),
                "suspendedCardEPDs": .strings(trainer.suspendedCardEPDs().map(\.rawValue).sorted()),
                "expectedMoves": .object(Dictionary(uniqueKeysWithValues: cardNodes.map { (String($0), J.s(trainer.expectedMove(at: $0)?.uci)) })),
                "allLines": .array(lines.map { .ints($0.nodes) }),
                "branchLines": .object(Dictionary(uniqueKeysWithValues: branches.map { b in
                    (String(b), J.array(trainer.allLines(under: b).map { .ints($0.nodes) }))
                })),
                "branchCardNodes": .object(Dictionary(uniqueKeysWithValues: branches.map { (String($0), J.ints(trainer.cardNodes(under: $0))) })),
                "newCardOrder": .strings(trainer.newCardOrder().map(\.rawValue)),
                "newCardOrderByReach": .strings(order.map(\.rawValue)),
                "newCardOrderByReachPerBranch": .object(Dictionary(uniqueKeysWithValues: branches.map {
                    (String($0), J.strings(trainer.newCardOrder(under: $0, reach: reach).map(\.rawValue)))
                })),
                "lineThrough": .object(Dictionary(uniqueKeysWithValues: cardNodes.prefix(200).map { id in
                    (String(id), J.ints(trainer.line(through: id, preferring: { reach[$0] ?? 0 }).nodes))
                })),
                "mixedCards": J.cards(cards),
                "progress": progress(trainer.progress(cards: cards)),
                "progressEmpty": progress(trainer.progress(cards: [:])),
            ]
            try Golden.write(out, to: "trainer/\(name).json", pretty: tree.count < 2000)
        }
    }

    @Test func queues() throws {
        var out: [String: J] = [:]
        // AnkiSchedulerTests.queueOrderAndCounts
        let noon = SchedTiming(daysElapsed: 100, nextDayAt: 1_000_000 + 16 * 3600, now: 1_000_000)
        var cards: [EPD: Card] = [:]
        func card(_ queue: Card.Queue, due: Int64, reps: Int = 1) -> Card {
            var c = Card(id: Int64(cards.count + 1), position: 0, added: 0)
            c.queue = queue
            c.ctype = queue == .review ? .review : .learn
            c.due = due
            c.reps = reps
            return c
        }
        cards[Self.epd("e4")] = card(.learn, due: noon.now - 10)
        cards[Self.epd("d4")] = card(.learn, due: noon.now + 600)
        cards[Self.epd("c4")] = card(.learn, due: noon.now + 3 * 3600)
        cards[Self.epd("Nf3")] = card(.review, due: 100)
        // A tie: equal due and both attempted; their order comes from dictionary iteration.
        cards[Self.epd("b3")] = card(.learn, due: noon.now - 5)
        cards[Self.epd("g3")] = card(.learn, due: noon.now - 5)
        cards[Self.epd("f4")] = card(.learn, due: noon.now - 5, reps: 0)
        let defaultLimits = RemainingLimits(config: DeckConfig(), limits: DeckLimits(), stats: DeckStudyStats(), today: 100)
        var q = CardQueues(cards: cards, newCards: [Self.epd("b4"), Self.epd("e4")], limits: defaultLimits, timing: noon)
        var steps: [J] = [["op": "build", "queue": J.queue(q, exact: false)]]
        q.remove(Self.epd("e4")); steps.append(["op": "remove", "epd": .string(Self.epd("e4").rawValue), "queue": J.queue(q, exact: false)])
        q.remove(Self.epd("Nf3")); steps.append(["op": "remove", "epd": .string(Self.epd("Nf3").rawValue), "queue": J.queue(q, exact: false)])
        q.updateLearningCutoff(now: noon.now + 2000); steps.append(["op": "updateLearningCutoff", "now": .i(noon.now + 2000), "queue": J.queue(q, exact: false)])
        out["anki_basic"] = ["timing": J.timing(noon), "cards": J.cards(cards), "newCards": .strings([Self.epd("b4").rawValue, Self.epd("e4").rawValue]),
                             "limits": J.limits(defaultLimits), "learnAheadSecs": 1200, "steps": .array(steps)]

        // Mixed cards over the Berlin repertoire with priorities and several limits.
        let tree = try Self.berlin()
        let trainer = Trainer(tree: tree, color: .black)
        let reach = Self.reach(tree, color: .black)
        let order = trainer.newCardOrder(reach: reach)
        let timing = Self.timing(day: 100, secondsIntoDay: 8 * 3600)
        let mixed = Self.mixedCards(trainer, order: order, timing: timing).filter { trainer.cardEPDSet.contains($0.key) }
        let epdReach = trainer.reachByEPD(reach)
        let priority: J = .object(Dictionary(uniqueKeysWithValues: epdReach.map { ($0.key.rawValue, J.double($0.value)) }))
        let limitCases: [(String, RemainingLimits)] = [
            ("default", defaultLimits),
            ("review5_new3", RemainingLimits(review: 5, new: 3, capNewToReview: true)),
            ("review2_cap", RemainingLimits(review: 2, new: 20, capNewToReview: true)),
            ("review2_nocap", RemainingLimits(review: 2, new: 20, capNewToReview: false)),
            ("unlimited", .unlimited),
            ("zero", RemainingLimits(review: 0, new: 0, capNewToReview: true)),
        ]
        var mixedOut: [String: J] = [:]
        for (lname, limits) in limitCases {
            for learnAhead in lname == "default" ? [1200, 0] : [1200] {
                var q = CardQueues(cards: mixed, newCards: order, limits: limits, timing: timing, learnAheadSecs: learnAhead,
                                   priority: { epdReach[$0] ?? 0 })
                var steps: [J] = [["op": "build", "queue": J.queue(q)]]
                // answer the first three shown, the learning one again
                for k in 0..<3 {
                    guard let (epd, _) = q.next else { break }
                    q.remove(epd)
                    steps.append(["op": "remove", "epd": .string(epd.rawValue), "queue": J.queue(q)])
                    let now = timing.now + Int64(10 * (k + 1))
                    let t = SchedTiming(daysElapsed: timing.daysElapsed, nextDayAt: timing.nextDayAt, now: now)
                    let answer = Scheduler().answer(mixed[epd], epd: epd, position: order.firstIndex(of: epd) ?? 0, rating: k == 1 ? .good : .again, timing: t)
                    q.answered(answer.card, epd: epd, timing: t)
                    steps.append(["op": "answered", "epd": .string(epd.rawValue), "card": J.card(answer.card), "timing": J.timing(t), "queue": J.queue(q)])
                }
                q.updateLearningCutoff(now: timing.now + 1500)
                steps.append(["op": "updateLearningCutoff", "now": .i(timing.now + 1500), "queue": J.queue(q)])
                mixedOut["\(lname).learnAhead\(learnAhead)"] = ["limits": J.limits(limits), "learnAheadSecs": .i(learnAhead), "steps": .array(steps)]
            }
        }
        out["berlin_mixed"] = ["timing": J.timing(timing), "cards": J.cards(mixed), "newCards": .strings(order.map(\.rawValue)),
                               "priority": priority, "cases": .object(mixedOut)]

        // Filtered (branch) queue: SplitMix64-seeded Fisher–Yates shuffle (Swift's `shuffle(using:)`).
        let branch = tree.find("e4 e5 Nf3 Nc6 Bb5") ?? tree[RepertoireTree.rootID]!.children[0]
        let branchOrder = trainer.newCardOrder(under: branch, reach: reach)
        var filteredOut: [J] = []
        for day in [100, 101, 5000] {
            let t = Self.timing(day: day, secondsIntoDay: 8 * 3600)
            filteredOut.append(["timing": J.timing(t), "queue": J.queue(CardQueues(filtered: branchOrder, cards: mixed, timing: t))])
        }
        out["berlin_filtered"] = ["branch": .i(branch), "epds": .strings(branchOrder.map(\.rawValue)), "cards": J.cards(mixed), "days": .array(filteredOut)]

        var rng = SplitMix64(seed: 12345)
        out["splitmix64"] = ["seed": 12345, "next": .array((0..<8).map { _ in .string(String(rng.next())) })]
        var shuffled = Array(0..<20)
        var srng = SplitMix64(seed: UInt64(100) &* 2_654_435_761)
        shuffled.shuffle(using: &srng)
        out["shuffle_0_to_19_day100"] = .ints(shuffled)

        let a = [1, 2, 3]
        out["intersperse"] = .array([[11, 22, 33], [11, 22], [11, 22, 33, 44, 55, 66], [11, 22, 33, 44, 55, 66, 77, 88], [], [11]].map { b in
            ["one": .ints(a), "two": .ints(b), "result": .ints(CardQueues.intersperse(a, b))]
        } + [["one": .ints([]), "two": .ints([5, 6]), "result": .ints(CardQueues.intersperse([], [5, 6]))]])

        // RemainingLimits(config:limits:stats:today:)
        var limitRows: [J] = []
        for ignore in [false, true] {
            var config = DeckConfig()
            config.newPerDay = 5
            config.reviewsPerDay = 10
            config.newCardsIgnoreReviewLimit = ignore
            var stats = DeckStudyStats()
            stats.recordAnswer(fromQueue: .new, millis: 10, today: 100)
            stats.recordAnswer(fromQueue: .review, millis: 20, today: 100)
            stats.recordAnswer(fromQueue: .dayLearn, millis: 30, today: 100)
            stats.recordAnswer(fromQueue: .learn, millis: 40, today: 100)
            var extended = stats
            extended.extendLimits(today: 100, new: 3, review: 4)
            var deck = DeckLimits()
            deck.newLimit = 8
            deck.reviewLimit = 12
            deck.newLimitToday = DayLimit(limit: 7, today: 100)
            for (sname, s) in [("none", DeckStudyStats()), ("studied", stats), ("extended", extended)] {
                for (dname, d) in [("default", DeckLimits()), ("deck", deck)] {
                    for today in [100, 101] {
                        limitRows.append(["newCardsIgnoreReviewLimit": .bool(ignore), "stats": .string(sname), "deckLimits": .string(dname),
                                          "today": .i(today), "result": J.limits(RemainingLimits(config: config, limits: d, stats: s, today: today))])
                    }
                }
            }
            limitRows.append(["statsValues": .raw(extended), "deckValues": .raw(deck)])
        }
        out["remainingLimits"] = .array(limitRows)
        try Golden.write(.object(out), to: "queue/queues.json", pretty: false)
    }

    /// Plays study sessions like DrillView: every asked move is answered (Again by hash, else
    /// Good), every move you play is recorded as played, time moves 7 s per move.
    @Test func sessions() throws {
        for (name, tree, color) in try Self.trainingTrees() {
            let trainer = Trainer(tree: tree, color: color)
            let reach = Self.reach(tree, color: color)
            let order = trainer.newCardOrder(reach: reach)
            let start = Self.timing(day: 100, secondsIntoDay: 8 * 3600)
            let mixed = Self.mixedCards(trainer, order: order, timing: start)
            let root = RepertoireTree.rootID
            let branch = tree[root]?.children.first.flatMap { tree[$0]?.children.first } ?? root
            var out: [String: J] = ["color": .string(color.rawValue), "reach": .object(Dictionary(uniqueKeysWithValues: reach.map { (String($0.key), J.double($0.value)) })),
                                    "t0": .i(Self.t0), "branch": .i(branch)]
            for (cname, initial) in [("empty", [EPD: Card]()), ("mixed", mixed)] {
                for mode in PracticeMode.allCases {
                    for filtered in [false, true] {
                        let limits = RemainingLimits(review: 30, new: 5, capNewToReview: true)
                        let session = filtered
                            ? StudySession(trainer: trainer, mode: mode, branch: branch, cards: initial, timing: start, reach: reach)
                            : StudySession(trainer: trainer, mode: mode, cards: initial, limits: limits, timing: start, reach: reach)
                        let key = "\(cname).\(mode.rawValue).\(filtered ? "branch" : "daily")"
                        out[key] = Self.simulate(session, cards: initial, limits: filtered ? nil : limits, start: start)
                    }
                }
            }
            try Golden.write(.object(out), to: "session/\(name).json", pretty: tree.count < 2000)
        }
    }

    static func simulate(_ initialSession: StudySession, cards initial: [EPD: Card], limits: RemainingLimits?, start: SchedTiming) -> J {
        var session = initialSession
        var cards = initial
        var now = start.now
        var lines: [J] = []
        var previous: [NodeID]?
        var stoppedOnTie = false
        var answerCount = 0
        var revlog: [RevlogEntry] = []
        let scheduler = Scheduler()
        let initialQueue = J.queue(session.queue)
        for _ in 0..<40 {
            session.updateLearningCutoff(now: now)
            // Only a daily queue takes its learning order from dictionary iteration.
            if !session.isFiltered, J.hasTieAtFront(session.queue) { stoppedOnTie = true; break }
            let countsBefore = session.queue.counts
            guard let line = session.nextLine(cards: cards) else {
                // wait for the next learning step later today
                guard let due = session.queue.nextLearningDue.map({ Int64($0.timeIntervalSince1970) }), due < start.nextDayAt else { break }
                lines.append(["waitUntil": .i(due)])
                now = max(now, due)
                continue
            }
            var record: [String: J] = ["now": .i(now), "countsBefore": J.counts(countsBefore), "line": J.studyLine(line),
                                       "resumeIndex": .i(previous.flatMap { line.resumeIndex(from: $0, shown: $0.count - 1) })]
            var answers: [J] = []
            for i in line.roles.keys.sorted() {
                guard let role = line.roles[i] else { continue }
                now += 7
                guard role != .auto, let epd = trainer(session).tree[line.nodes[i]]?.epd else { continue }
                if case .answer(let kind) = role {
                    let rating: Rating = Golden.fnv(epd.rawValue + String(answerCount)) % 4 == 0 ? .again : .good
                    answerCount += 1
                    let timing = SchedTiming(daysElapsed: start.daysElapsed, nextDayAt: start.nextDayAt, now: now)
                    let filtered = session.isFiltered || kind == .reviewAhead
                    let result = scheduler.answer(cards[epd], epd: epd, position: session.position(of: epd), rating: rating,
                                                  timing: timing, filtered: filtered, takenMillis: 7000)
                    cards[epd] = result.card
                    revlog.append(result.revlog)
                    session.didAnswer(epd, card: result.card, timing: timing)
                    answers.append(["index": .i(i), "epd": .string(epd.rawValue), "rating": .i(rating.rawValue), "filtered": .bool(filtered),
                                    "position": .i(session.position(of: epd)), "card": J.card(result.card), "fromQueue": .i(result.fromQueue.rawValue)])
                }
                session.didPlay(epd)
            }
            record["answers"] = .array(answers)
            record["countsAfter"] = J.counts(session.queue.counts)
            lines.append(.object(record))
            previous = line.nodes
        }
        return ["limits": limits.map(J.limits) ?? .null, "startTiming": J.timing(start), "initialQueue": initialQueue,
                "lines": .array(lines), "stoppedOnTie": .bool(stoppedOnTie), "finalCards": J.cards(cards),
                "revlog": .array(revlog.map { .raw($0) }), "answered": .strings(session.answered.map(\.rawValue).sorted()),
                "played": .strings(session.played.map(\.rawValue).sorted())]
    }

    static func trainer(_ s: StudySession) -> Trainer { s.trainer }

    // MARK: Files and ids

    @Test func filesAndIDs() throws {
        let tree = try Self.berlin()
        var epds = Set(tree.nodes.values.map(\.epd))
        epds.insert(EPD(rawValue: ""))
        epds.insert(EPD(rawValue: "8/8/8/8/8/8/8/8 w - -"))
        epds.insert(EPD(rawValue: "ünïcödé"))
        let ids = epds.sorted().map { e -> J in ["epd": .string(e.rawValue), "id": .i(Card.id(for: e))] }
        try Golden.write(["cardIDs": .array(ids)], to: "misc/card_ids.json")

        let scheduler = Scheduler()
        let timing = Self.timing(day: 2400, secondsIntoDay: 9 * 3600)
        let e1 = ChessPosition.start.epd, e2 = Self.epd("e4"), e3 = Self.epd("e4 e5"), e4 = Self.epd("d4 d5 c4")
        var revlog: [RevlogEntry] = []
        var studyCards: [EPD: Card] = [:]
        for (i, (e, ratings)) in [(e1, [Rating.good, .good]), (e2, [.again]), (e3, [.good, .good, .good]), (e4, [.good, .again, .good])].enumerated() {
            var card: Card?
            var t = timing
            for r in ratings {
                let a = scheduler.answer(card, epd: e, position: i, rating: r, timing: t, takenMillis: 1234 + i, answeredAt: t.now * 1000 + Int64(i))
                card = a.card
                revlog.append(a.revlog)
                t = a.card.queue == .learn ? Self.timing(at: a.card.due) : Self.timing(day: Int(a.card.due), secondsIntoDay: 9 * 3600)
            }
            studyCards[e] = card
        }
        var suspended = studyCards[e2]!
        suspended.queue = .suspended
        suspended.leech = true
        studyCards[Self.epd("c4")] = suspended

        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let modified = Date(timeIntervalSince1970: 1_790_000_000.25)
        var minimal = Sidecar(id: id, color: .white)
        minimal.settingsModified = modified
        var full = Sidecar(id: id, color: .black, database: .lichess(speeds: [.rapid, .blitz], ratings: [2000, 1800]), targetGames: 400, minGames: 30)
        full.settingsModified = modified
        full.studyCards = studyCards
        var stats = DeckStudyStats()
        stats.recordAnswer(fromQueue: .new, millis: 1500, today: 2400)
        stats.recordAnswer(fromQueue: .review, millis: 2500, today: 2400)
        full.studyStats = stats
        var limits = DeckLimits()
        limits.newLimit = 10
        limits.reviewLimitToday = DayLimit(limit: 50, today: 2400)
        full.limits = limits
        full.practiceMode = .completeLinesOncePerSession
        full.summary = Sidecar.Summary(completion: 0.4375, gapCount: 12, cardCount: 120, matureCount: 7, savedMoveCount: 380,
                                       suspendedCount: 3, dueCount: 9, configKey: full.configKey, computedAt: Date(timeIntervalSince1970: 1_790_000_100.5))
        full.lastLine = ["e2e4", "e7e5", "g1f3"]
        full.excludedMoves = [e2: ["c7c5", "e7e6"], e3: ["b8c6"]]
        var masters = Sidecar(id: id, color: .white, database: .masters, targetGames: 1000, minGames: 5)
        masters.settingsModified = modified
        masters.summary = Sidecar.Summary(completion: 1, gapCount: 0, cardCount: 0, matureCount: 0, dueCount: 0, configKey: masters.configKey,
                                          computedAt: Date(timeIntervalSince1970: 1_790_000_000))
        var sidecarInfo: [String: J] = [:]
        for (name, sidecar) in [("minimal", minimal), ("full", full), ("masters", masters)] {
            let data = try sidecar.encoded()
            try Golden.write(data, to: "misc/sidecar_\(name).otrep.json")
            let reencoded = try Sidecar.decode(data).encoded()
            let counts = sidecar.estimatedStudyCounts(config: DeckConfig(), timing: timing)
            let progress = sidecar.estimatedProgress
            sidecarInfo[name] = [
                "configKey": .string(sidecar.configKey), "databaseCacheKey": .string(sidecar.database.cacheKey),
                "databaseSummary": .string(sidecar.database.summary), "roundTripEqual": .bool(reencoded == data),
                "estimatedStudyCounts": J.counts(counts),
                "estimatedProgress": ["cards": .i(progress.cards), "learning": .i(progress.learning), "young": .i(progress.young),
                                      "mature": .i(progress.mature), "suspended": .i(progress.suspended)],
                "nextDue": .i(sidecar.nextDue(timing: timing).map { Int64($0.timeIntervalSince1970) }),
                "laterLearningDues": .array(sidecar.laterLearningDues(timing: timing).map { .i(Int64($0.timeIntervalSince1970)) }),
                "dueTomorrow": .i(sidecar.dueTomorrow(timing: timing)),
            ]
        }
        var other = full
        other.settingsModified = modified.addingTimeInterval(10)
        other.targetGames = 600
        var newer = studyCards[e1]!
        newer.lastReviewTime = (newer.lastReviewTime ?? 0) + 100
        newer.reps += 1
        other.studyCards = [e1: newer, Self.epd("Nf3"): studyCards[e3]!]
        var otherStats = DeckStudyStats()
        otherStats.recordAnswer(fromQueue: .new, millis: 9000, today: 2400)
        otherStats.recordAnswer(fromQueue: .new, millis: 9000, today: 2400)
        other.studyStats = otherStats
        try Golden.write(try other.encoded(), to: "misc/sidecar_other.otrep.json")
        try Golden.write(try full.merged(with: other).encoded(), to: "misc/sidecar_full_merged_other.otrep.json")
        var synced = full
        let changed = synced.syncSuspension(active: [e1, e3, Self.epd("c4")])
        try Golden.write(try synced.encoded(), to: "misc/sidecar_full_synced.otrep.json")
        sidecarInfo["syncSuspension"] = ["active": .strings([e1, e3, Self.epd("c4")].map(\.rawValue)), "changed": .bool(changed)]
        sidecarInfo["timing"] = J.timing(timing)
        try Golden.write(.object(sidecarInfo), to: "misc/sidecar_info.json")

        try Golden.write(RevlogFile.encode(revlog), to: "misc/revlog.otlog.jsonl")
        var mixed = RevlogFile.encode(Array(revlog.suffix(3)))
        mixed.append(Data("not json\n\n{\"id\":1}\n".utf8))
        mixed.append(RevlogFile.encode(Array(revlog.prefix(3))))
        try Golden.write(mixed, to: "misc/revlog_unsorted_with_garbage.otlog.jsonl")
        let decoded = RevlogFile.decode(mixed)
        try Golden.write(RevlogFile.encode(decoded), to: "misc/revlog_unsorted_with_garbage.decoded.otlog.jsonl")
        var manual = revlog[0]
        manual.ease = 0
        manual.type = .manual
        manual.factor = 0
        manual.id += 5
        let merged = RevlogFile.merged(Array(revlog.prefix(4)), Array(revlog.suffix(4)) + [manual])
        try Golden.write(RevlogFile.encode(merged), to: "misc/revlog_merged.otlog.jsonl")
    }
}
