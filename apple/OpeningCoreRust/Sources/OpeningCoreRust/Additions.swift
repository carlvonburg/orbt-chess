// Swift conveniences over the generated bindings (opening_core.swift): names, conformances
// and computed values the views use. No rules live here; they are in the Rust core.

import Foundation

public typealias NodeID = UInt32
public typealias EPD = Epd
public typealias ChessPosition = Position

public enum RepertoireTree {
    public static let rootID: NodeID = 0
}

public enum SAN {
    /// Normalized and without check/mate marks, for comparing moves.
    public static func loose(_ san: String) -> String { sanLoose(san: san) }
}

// MARK: Chess

extension BoardSquare: CustomStringConvertible {
    public init(index: Int) { self.init(index: UInt8(index)) }
    public init(file: Int, rank: Int) { self.init(index: UInt8(rank * 8 + file)) }

    /// Algebraic notation, e.g. "e4".
    public init?(_ notation: some StringProtocol) {
        guard let square = squareFromNotation(notation: String(notation)) else { return nil }
        self = square
    }

    public var file: Int { Int(index) % 8 }
    public var rank: Int { Int(index) / 8 }
    public var isLight: Bool { (file + rank) % 2 == 1 }
    public var description: String {
        String(UnicodeScalar(UInt8(97 + file))) + String(rank + 1)
    }
}

extension PlayedMove {
    public var from: BoardSquare { BoardSquare(uci.prefix(2))! }
    public var to: BoardSquare { BoardSquare(uci.dropFirst(2).prefix(2))! }
}

extension Side: CaseIterable, RawRepresentable, Codable {
    public static var allCases: [Side] { [.white, .black] }
    public init?(rawValue: String) {
        switch rawValue {
        case "white": self = .white
        case "black": self = .black
        default: return nil
        }
    }
    // A switch, not `==`: with RawRepresentable, `==` compares raw values and would recurse.
    public var rawValue: String {
        switch self {
        case .white: "white"
        case .black: "black"
        }
    }
    public var opposite: Side {
        switch self {
        case .white: .black
        case .black: .white
        }
    }
}

extension PieceKind: CaseIterable, RawRepresentable {
    public static var allCases: [PieceKind] { [.pawn, .knight, .bishop, .rook, .queen, .king] }
    public init?(rawValue: String) {
        guard let kind = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = kind
    }
    public var rawValue: String {
        switch self {
        case .pawn: "p"
        case .knight: "n"
        case .bishop: "b"
        case .rook: "r"
        case .queen: "q"
        case .king: "k"
        }
    }
}

extension Position {
    public func legalDestinations(from square: BoardSquare) -> [BoardSquare] { legalDestinations(square: square) }
    public func piece(at square: BoardSquare) -> BoardPiece? { pieceAt(square: square) }
}

extension Node {
    /// The move that leads here; nil for the root.
    public var move: PlayedMove? { mv }
}

// MARK: Explorer

extension ExplorerSpeed: CaseIterable, RawRepresentable, Identifiable {
    public static var allCases: [ExplorerSpeed] { [.ultraBullet, .bullet, .blitz, .rapid, .classical, .correspondence] }
    public init?(rawValue: String) {
        guard let speed = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = speed
    }
    public var rawValue: String {
        switch self {
        case .ultraBullet: "ultraBullet"
        case .bullet: "bullet"
        case .blitz: "blitz"
        case .rapid: "rapid"
        case .classical: "classical"
        case .correspondence: "correspondence"
        }
    }
    public var id: String { rawValue }
    public var title: String { explorerSpeedTitle(speed: self) }
}

extension ExplorerDatabase {
    public static var defaultLichess: ExplorerDatabase { databaseDefaultLichess() }
    public static var ratingBuckets: [Int] { databaseRatingBuckets().map(Int.init) }
    public var cacheKey: String { databaseCacheKey(database: self) }
    public var summary: String { databaseSummary(database: self) }
}

extension ExplorerMove {
    public var games: Int { Int(white + draws + black) }
    public func score(for side: Side) -> Double { explorerMoveScore(mv: self, side: side) }
}

extension ExplorerStats {
    public var total: Int { Int(white + draws + black) }
    public func share(of uci: String) -> Double { explorerStatsShare(stats: self, uci: uci) }
    public func move(_ uci: String) -> ExplorerMove? { moves.first { $0.uci == uci } }
}

// MARK: Coverage

extension CoverageGap {
    /// "Seen once every N games".
    public var seenEvery: Int { Int(gapSeenEvery(gap: self)) }
}

extension NodeCoverage {
    public var seenEvery: Int? { coverageSeenEvery(coverage: self).map(Int.init) }
}

// MARK: Training

extension Card {
    public var isMature: Bool { cardIsMature(card: self) }
    public var isLearning: Bool { queue == .learn || queue == .dayLearn }
    public func retrievability(at now: Date) -> Double? {
        cardRetrievability(card: self, nowSecs: now.timeIntervalSince1970)
    }
}

extension RevlogEntry {
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(id) / 1000) }
    public var hasRating: Bool { ease > 0 }
}

extension Counts {
    public init() { self.init(new: 0, learning: 0, review: 0) }
    public var total: Int { Int(new + learning + review) }
}

extension Progress {
    public init() { self.init(cards: 0, learning: 0, young: 0, mature: 0, suspended: 0) }
    public var studied: Int { Int(learning + young + mature) }
    public var notStudied: Int { Int(cards) - studied }
}

extension CardCounts {
    public var total: Int { Int(new + learn + relearn + young + mature + suspended) }
}

extension ReviewCounts {
    public init() { self.init(learn: 0, relearn: 0, young: 0, mature: 0, filtered: 0) }
    public var total: Int { Int(learn + relearn + young + mature + filtered) }
}

extension TrueRetention {
    public var young: Double? { retentionRateYoung(r: self) }
    public var mature: Double? { retentionRateMature(r: self) }
    public var total: Double? { retentionRateTotal(r: self) }
    public var count: Int { Int(youngPassed + youngFailed + maturePassed + matureFailed) }
}

extension DeckLimits {
    public init() { self.init(newLimit: nil, newLimitToday: nil, reviewLimit: nil, reviewLimitToday: nil) }
    public var isEmpty: Bool { self == DeckLimits() }
}

extension PracticeMode: CaseIterable, RawRepresentable, Identifiable {
    public static var allCases: [PracticeMode] { [.individualMoves, .completeLinesEveryTime, .completeLinesOncePerSession] }
    public static var `default`: PracticeMode { .individualMoves }
    public init?(rawValue: String) {
        guard let mode = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = mode
    }
    public var rawValue: String {
        switch self {
        case .individualMoves: "individualMoves"
        case .completeLinesEveryTime: "completeLinesEveryTime"
        case .completeLinesOncePerSession: "completeLinesOncePerSession"
        }
    }
    public var id: String { rawValue }
    public var title: String { practiceModeTitle(mode: self) }
}

extension GraphRange: CaseIterable, Identifiable {
    public static var allCases: [GraphRange] { [.month, .threeMonths, .year, .all] }
    public var id: Self { self }
    public var title: String { rangeTitle(range: self) }
    /// Days the range covers; 0 for all time.
    public var days: Int { Int(rangeDays(range: self)) }
}

extension RetentionPeriod: CaseIterable, Identifiable {
    public static var allCases: [RetentionPeriod] { [.today, .yesterday, .week, .month, .year, .allTime] }
    public var id: Self { self }
    public var title: String { retentionPeriodTitle(period: self) }
}

// MARK: Time

extension SchedTiming {
    public static let rolloverHour = 4

    /// "Today" for scheduling from the local calendar: days since 1 Jan 2020 (local time),
    /// rolling over at 4 AM, and when the next day starts. The Rust core takes these numbers,
    /// as Anki takes the UTC offset from its caller.
    public init(now: Date = .now, rolloverHour: Int = SchedTiming.rolloverHour, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: now)
        let rolloverToday = calendar.date(bySettingHour: rolloverHour, minute: 0, second: 0, of: start) ?? start
        let passed = rolloverToday <= now
        let nextDay = passed ? calendar.date(byAdding: .day, value: 1, to: rolloverToday) ?? rolloverToday : rolloverToday
        let epoch = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: epoch), to: start).day ?? 0
        self.init(daysElapsed: Int64(max(0, passed ? days : days - 1)),
                  nextDayAt: Int64(nextDay.timeIntervalSince1970),
                  now: Int64(now.timeIntervalSince1970))
    }

    /// Unix seconds when today started.
    public var dayStart: Int64 { nextDayAt - 86_400 }

    /// The approximate date a day number starts.
    public func date(ofDay day: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(dayStart + (day - daysElapsed) * 86_400))
    }
}

extension Timestamp {
    /// Milliseconds since 1970 for a date (the core's timestamps).
    public static func of(_ date: Date) -> Timestamp { Timestamp(date.timeIntervalSince1970 * 1000) }
}

// MARK: Statistics

extension Graphs {
    /// True retention by period, of the cards in `positions` if given.
    public func retentionTable(positions: [Epd]? = nil) -> [RetentionPeriod: TrueRetention] {
        Dictionary(trueRetention(positions: positions).map { ($0.period, $0.retention) }, uniquingKeysWith: { a, _ in a })
    }
}

extension TrueRetention {
    public init() { self.init(youngPassed: 0, youngFailed: 0, maturePassed: 0, matureFailed: 0) }
}

extension Streak {
    public init() { self.init(current: 0, longest: 0, studiedToday: false) }
}

extension WeakMove: Identifiable {
    public var id: Epd { epd }
}

extension Dictionary where Key == Int64 {
    /// The same values keyed by `Int`, for charts.
    public var intKeys: [Int: Value] { Dictionary<Int, Value>(uniqueKeysWithValues: map { (Int($0.key), $0.value) }) }
}

extension Dictionary where Key == Int64, Value == Int64 {
    public var ints: [Int: Int] { Dictionary<Int, Int>(uniqueKeysWithValues: map { (Int($0.key), Int($0.value)) }) }
}
