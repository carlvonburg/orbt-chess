import Foundation
@testable import OpeningCore

/// A JSON value for golden fixtures: written with sorted keys, ids as ints, doubles as Swift
/// prints them (shortest round-trip form; whole numbers without a fraction, e.g. `1`).
indirect enum J: Encodable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([J])
    case object([String: J])
    /// A value in its own Codable form (cards and revlog entries, as in the sidecar and log).
    case raw(any Encodable)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case .bool(let v):
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case .int(let v):
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case .double(let v):
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case .string(let v):
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case .array(let v):
            var c = encoder.unkeyedContainer()
            for item in v { try c.encode(item) }
        case .object(let v):
            var c = encoder.container(keyedBy: Name.self)
            for (k, item) in v { try c.encode(item, forKey: Name(k)) }
        case .raw(let v):
            try v.encode(to: encoder)
        }
    }

    private struct Name: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func i(_ v: Int) -> J { .int(Int64(v)) }
    static func i(_ v: Int64) -> J { .int(v) }
    static func i(_ v: Int?) -> J { v.map { .int(Int64($0)) } ?? .null }
    static func i(_ v: Int64?) -> J { v.map { .int($0) } ?? .null }
    static func d(_ v: Double?) -> J { v.map { .double($0) } ?? .null }
    static func s(_ v: String?) -> J { v.map { .string($0) } ?? .null }
    static func ints(_ v: [Int]) -> J { .array(v.map { .int(Int64($0)) }) }
    static func strings(_ v: [String]) -> J { .array(v.map { .string($0) }) }
}

extension J: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(Int64(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: J...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, J)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    init(nilLiteral: ()) { self = .null }
}

enum Golden {
    static var enabled: Bool { ProcessInfo.processInfo.environment["OT_WRITE_GOLDENS"] == "1" }

    /// `<repo>/core/fixtures`, from this file's location.
    static let fixtures: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("core/fixtures")

    /// The large test PGNs: `$OT_TESTDATA`, or `testData` next to the repo.
    static var testData: URL {
        if let dir = ProcessInfo.processInfo.environment["OT_TESTDATA"] { return URL(fileURLWithPath: dir) }
        return fixtures.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("testData")
    }

    @discardableResult
    static func write(_ value: J, to path: String, pretty: Bool = true) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            : [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        return try write(data, to: path)
    }

    @discardableResult
    static func write(_ text: String, to path: String) throws -> Int {
        try write(Data(text.utf8), to: path)
    }

    @discardableResult
    static func write(_ data: Data, to path: String) throws -> Int {
        let url = fixtures.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data.count
    }

    static func fnv(_ s: String) -> UInt64 { CoveragePropertyTests.fnv(s) }

    static func fnvHex(_ data: Data) -> String {
        var h: UInt64 = 14695981039346656037
        for b in data { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(format: "%016llx", h)
    }

    static func compactJSON(_ value: J) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

// MARK: Converters

extension J {
    static func pgnMove(_ m: PGNMove) -> J {
        ["san": .string(m.san), "nags": .ints(m.nags), "preComments": .strings(m.preComments),
         "comments": .strings(m.comments), "children": .array(m.children.map(pgnMove))]
    }

    static func pgnGame(_ g: PGNGame) -> J {
        ["tags": .array(g.tags.map { ["name": .string($0.name), "value": .string($0.value)] }),
         "comments": .strings(g.comments), "moves": .array(g.moves.map(pgnMove)), "result": .string(g.result)]
    }

    static func node(_ n: RepertoireNode, tree: RepertoireTree) -> J {
        ["id": .i(n.id), "parent": .i(n.parent), "san": .s(n.move?.san), "uci": .s(n.move?.uci),
         "fen": .string(n.fen), "epd": .string(n.epd.rawValue), "ply": .i(n.ply), "children": .ints(n.children),
         "chapters": .ints(n.chapters.sorted()), "comments": .strings(n.comments), "preComments": .strings(n.preComments),
         "nags": .ints(n.nags), "note": .string(n.note), "sideToMove": .string(n.sideToMove.rawValue),
         "transpositionTarget": .i(tree.transpositionTarget(of: n.id))]
    }

    static func tree(_ t: RepertoireTree) -> J {
        let ids = t.nodes.keys.sorted()
        let index = t.epdIndex.mapValues { J.ints($0) }
        let text = t.pgnText()
        let reread = RepertoireTree(pgn: text)
        return [
            "count": .i(t.count),
            "nodes": .array(ids.map { node(t[$0]!, tree: t) }),
            "chapters": .array(t.chapters.map { c in
                ["tags": .array(c.tags.map { ["name": .string($0.name), "value": .string($0.value)] }),
                 "comments": .strings(c.comments), "result": .string(c.result), "name": .string(c.name),
                 "passthrough": c.passthrough.map(pgnGame) ?? .null]
            }),
            "epdIndex": .object(Dictionary(uniqueKeysWithValues: index.map { ($0.key.rawValue, $0.value) })),
            "loadWarnings": .strings(t.loadWarnings),
            "mergedTranspositions": .i(t.mergedTranspositions),
            "rereadCount": .i(reread.count),
            "rereadPGNTextEqual": .bool(reread.pgnText() == text),
        ]
    }

    static func stats(_ s: ExplorerStats?) -> J {
        guard let s else { return .null }
        return ["white": .i(s.white), "draws": .i(s.draws), "black": .i(s.black),
                "moves": .array(s.moves.map { m in
                    ["uci": .string(m.uci), "san": .string(m.san), "white": .i(m.white), "draws": .i(m.draws),
                     "black": .i(m.black), "averageRating": .i(m.averageRating)]
                })]
    }

    static func status(_ s: NodeCoverage.Status) -> J {
        switch s {
        case .required: ["kind": "required"]
        case .belowTarget: ["kind": "belowTarget"]
        case .pending: ["kind": "pending"]
        case .unknown: ["kind": "unknown"]
        case .gap: ["kind": "gap"]
        case .transposition(let id): ["kind": "transposition", "target": .i(id)]
        case .alternative: ["kind": "alternative"]
        }
    }

    static func gap(_ g: CoverageGap?) -> J {
        guard let g else { return .null }
        let kind: J
        switch g.kind {
        case .missingMove: kind = ["kind": "missingMove"]
        case let .missingReply(uci, san): kind = ["kind": "missingReply", "uci": .string(uci), "san": .string(san)]
        }
        return ["node": .i(g.node), "kind": kind, "mass": .double(g.mass), "seenEvery": .i(g.seenEvery)]
    }

    static func reply(_ r: ReplyInfo) -> J {
        ["uci": .string(r.uci), "san": .string(r.san), "share": .double(r.share), "reach": .double(r.reach),
         "required": .bool(r.required), "excluded": .bool(r.excluded), "child": .i(r.child),
         "transposesTo": .i(r.transposesTo), "completion": .double(r.completion), "games": .i(r.games)]
    }

    static func coverage(_ c: NodeCoverage) -> J {
        ["reach": .d(c.reach), "status": status(c.status), "completion": .double(c.completion),
         "gapCount": .i(c.gapCount), "gapMass": .double(c.gapMass), "pendingCount": .i(c.pendingCount),
         "biggestGap": gap(c.biggestGap), "localGaps": .array(c.localGaps.map { gap($0) }),
         "replies": .array(c.replies.map(reply)), "counts": .bool(c.counts), "seenEvery": .i(c.seenEvery)]
    }

    static func settings(_ s: CoverageSettings) -> J {
        ["color": .string(s.color.rawValue), "targetGames": .i(s.targetGames), "minGames": .i(s.minGames),
         "excluded": .object(Dictionary(uniqueKeysWithValues: s.excluded.map { ($0.key.rawValue, J.strings($0.value.sorted())) }))]
    }

    /// Per-node coverage plus the engine's lists. `pendingPositions` is sorted by reach
    /// (descending), then EPD: Swift's order among equal reaches is dictionary order.
    static func engine(_ e: CoverageEngine, tree: RepertoireTree) -> J {
        let ids = e.info.keys.sorted()
        let pending = e.pendingPositions(tree: tree).sorted {
            $0.reach != $1.reach ? $0.reach > $1.reach : $0.epd < $1.epd
        }
        return [
            "nodes": .object(Dictionary(uniqueKeysWithValues: ids.map { (String($0), coverage(e[$0]!)) })),
            "root": e.root.map(coverage) ?? .null,
            "gaps": .array(e.gaps().map { gap($0) }),
            "pendingPositions": .array(pending.map { ["epd": .string($0.epd.rawValue), "reach": .double($0.reach)] }),
        ]
    }

    static func timing(_ t: SchedTiming) -> J {
        ["daysElapsed": .i(t.daysElapsed), "nextDayAt": .i(t.nextDayAt), "now": .i(t.now)]
    }

    static func memory(_ m: MemoryState?) -> J {
        guard let m else { return .null }
        return ["stability": .double(m.stability), "difficulty": .double(m.difficulty)]
    }

    static func interval(_ k: IntervalKind) -> J {
        switch k {
        case .secs(let s): ["secs": .i(s)]
        case .days(let d): ["days": .i(d)]
        }
    }

    static func learn(_ s: LearnState) -> J {
        ["remainingSteps": .i(s.remainingSteps), "scheduledSecs": .i(s.scheduledSecs),
         "elapsedSecs": .i(s.elapsedSecs), "memory": memory(s.memory)]
    }

    static func review(_ s: ReviewState) -> J {
        ["scheduledDays": .i(s.scheduledDays), "elapsedDays": .i(s.elapsedDays), "easeFactor": .double(s.easeFactor),
         "lapses": .i(s.lapses), "leeched": .bool(s.leeched), "memory": memory(s.memory)]
    }

    static func state(_ s: CardState) -> J {
        var o: [String: J]
        switch s {
        case .new(let n): o = ["kind": "new", "position": .i(n.position)]
        case .learning(let l): o = ["kind": "learning", "learning": learn(l)]
        case .review(let r): o = ["kind": "review", "review": review(r)]
        case .relearning(let r): o = ["kind": "relearning", "learning": learn(r.learning), "review": review(r.review)]
        }
        o["intervalKind"] = interval(s.intervalKind)
        o["revlogKind"] = .i(s.revlogKind.rawValue)
        o["leeched"] = .bool(s.leeched)
        return .object(o)
    }

    static func states(_ s: SchedulingStates) -> J {
        ["current": state(s.current), "again": state(s.again), "hard": state(s.hard), "good": state(s.good), "easy": state(s.easy)]
    }

    static func card(_ c: Card?) -> J { c.map { .raw($0) } ?? .null }

    static func cards(_ cards: [EPD: Card]) -> J {
        .object(Dictionary(uniqueKeysWithValues: cards.map { ($0.key.rawValue, J.raw($0.value)) }))
    }

    static func config(_ c: DeckConfig) -> J {
        ["newPerDay": .i(c.newPerDay), "reviewsPerDay": .i(c.reviewsPerDay),
         "newCardsIgnoreReviewLimit": .bool(c.newCardsIgnoreReviewLimit),
         "learnSteps": .array(c.learnSteps.map { .double($0) }), "relearnSteps": .array(c.relearnSteps.map { .double($0) }),
         "graduatingIntervalGood": .i(c.graduatingIntervalGood), "graduatingIntervalEasy": .i(c.graduatingIntervalEasy),
         "initialEase": .double(c.initialEase), "easyMultiplier": .double(c.easyMultiplier),
         "hardMultiplier": .double(c.hardMultiplier), "lapseMultiplier": .double(c.lapseMultiplier),
         "intervalMultiplier": .double(c.intervalMultiplier), "maximumReviewInterval": .i(c.maximumReviewInterval),
         "minimumLapseInterval": .i(c.minimumLapseInterval), "leechThreshold": .i(c.leechThreshold),
         "leechAction": c.leechAction == .suspend ? "suspend" : "tagOnly", "desiredRetention": .double(c.desiredRetention),
         "capAnswerTimeToSecs": .i(c.capAnswerTimeToSecs), "learnAheadSecs": .i(c.learnAheadSecs),
         "fsrsShortTermWithStepsEnabled": .bool(c.fsrsShortTermWithStepsEnabled)]
    }

    static func limits(_ l: RemainingLimits) -> J {
        ["review": .i(l.review), "new": .i(l.new), "capNewToReview": .bool(l.capNewToReview)]
    }

    static func counts(_ c: CardQueues.Counts) -> J {
        ["new": .i(c.new), "learning": .i(c.learning), "review": .i(c.review)]
    }

    static func kind(_ k: CardQueues.Kind) -> J {
        switch k {
        case .new: "new"
        case .learning: "learning"
        case .review: "review"
        }
    }

    static func mainKind(_ k: CardQueues.MainKind) -> J {
        switch k {
        case .new: "new"
        case .review: "review"
        case .interdayLearning: "interdayLearning"
        }
    }

    /// The queue's state. Intraday learning entries that compare equal (same due, both or
    /// neither previously attempted) are grouped and sorted by EPD: their order in Swift
    /// comes from dictionary iteration. `ordered` is grouped the same way.
    /// `exact: false` leaves out the exact lists, for a queue whose ties come from dictionary order.
    static func queue(_ q: CardQueues, exact: Bool = true) -> J {
        let groups = learningGroups(q.intradayLearning)
        let cutoff = q.currentLearningCutoff, ahead = q.learnAheadCutoff
        func groupJ(_ g: [CardQueues.LearningEntry]) -> J {
            .array(g.sorted { $0.epd < $1.epd }.map { ["epd": .string($0.epd.rawValue), "due": .i($0.due), "reps": .i($0.reps)] })
        }
        var ordered: [J] = []
        for g in groups { let now = g.filter { $0.due <= cutoff }; if !now.isEmpty { ordered.append(.array(now.map { .string($0.epd.rawValue) }.sortedJ())) } }
        for m in q.main { ordered.append([.string(m.epd.rawValue)]) }
        for g in groups {
            let later = g.filter { $0.due > cutoff && $0.due <= ahead }
            if !later.isEmpty { ordered.append(.array(later.map { .string($0.epd.rawValue) }.sortedJ())) }
        }
        var out: [String: J] = [
            "counts": counts(q.counts),
            "currentDay": .i(q.currentDay),
            "learnAheadSecs": .i(q.learnAheadSecs),
            "currentLearningCutoff": .i(q.currentLearningCutoff),
            "main": .array(q.main.map { ["epd": .string($0.epd.rawValue), "kind": mainKind($0.kind)] }),
            "intradayLearningGroups": .array(groups.map(groupJ)),
            "intradayLearning": .array(q.intradayLearning.map { ["epd": .string($0.epd.rawValue), "due": .i($0.due), "reps": .i($0.reps)] }),
            "ordered": .array(q.ordered.map { [.string($0.0.rawValue), kind($0.1)] }),
            "orderedGroups": .array(ordered),
            "orderedKinds": .object(Dictionary(q.ordered.map { ($0.0.rawValue, kind($0.1)) }, uniquingKeysWith: { a, _ in a })),
            "nextLearningDue": .i(q.nextLearningDue.map { Int64($0.timeIntervalSince1970) }),
            "hasTieAtFront": .bool(hasTieAtFront(q)),
        ]
        if !exact {
            out["intradayLearning"] = nil
            out["ordered"] = nil
        }
        return .object(out)
    }

    static func learningGroups(_ entries: [CardQueues.LearningEntry]) -> [[CardQueues.LearningEntry]] {
        var groups: [[CardQueues.LearningEntry]] = []
        for e in entries {
            if let last = groups.last?.last, !last.precedes(e), !e.precedes(last) {
                groups[groups.count - 1].append(e)
            } else {
                groups.append([e])
            }
        }
        return groups
    }

    /// Whether the first card shown depends on Swift's dictionary order.
    static func hasTieAtFront(_ q: CardQueues) -> Bool {
        let groups = learningGroups(q.intradayLearning)
        if let first = groups.first(where: { $0.contains { $0.due <= q.currentLearningCutoff } }) {
            return first.filter { $0.due <= q.currentLearningCutoff }.count > 1
        }
        if !q.main.isEmpty { return false }
        let ahead = groups.first { $0.contains { $0.due > q.currentLearningCutoff && $0.due <= q.learnAheadCutoff } }
        return (ahead?.count ?? 0) > 1
    }

    static func role(_ r: MoveRole) -> J {
        switch r {
        case .auto: "auto"
        case .practice: "practice"
        case .answer(.queued): "answer.queued"
        case .answer(.introduce): "answer.introduce"
        case .answer(.reviewAhead): "answer.reviewAhead"
        }
    }

    static func studyLine(_ l: StudyLine) -> J {
        ["nodes": .ints(l.nodes), "target": .string(l.target.rawValue),
         "roles": .object(Dictionary(uniqueKeysWithValues: l.roles.map { (String($0.key), role($0.value)) }))]
    }
}

private extension Array where Element == J {
    func sortedJ() -> [J] {
        sorted { a, b in
            if case .string(let x) = a, case .string(let y) = b { return x < y }
            return false
        }
    }
}

/// Records every stats lookup, so the fixture carries the exact stats the engine saw.
final class StatsRecorder {
    var seen: [EPD: ExplorerStats?] = [:]
    let source: (EPD) -> ExplorerStats?

    init(_ source: @escaping (EPD) -> ExplorerStats?) { self.source = source }

    func lookup(_ epd: EPD) -> ExplorerStats? {
        if let v = seen[epd] { return v }
        let v = source(epd)
        seen[epd] = .some(v)
        return v
    }

    var json: J {
        .object(Dictionary(uniqueKeysWithValues: seen.map { ($0.key.rawValue, J.stats($0.value)) }))
    }
}
