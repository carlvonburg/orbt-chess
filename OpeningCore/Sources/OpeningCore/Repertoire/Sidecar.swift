import Foundation

/// Everything about a repertoire that is not moves: stored next to the PGN as
/// `<Name>.otrep.json` so the PGN stays clean for other chess programs.
public struct Sidecar: Codable, Sendable, Equatable {
    enum CodingKeys: String, CodingKey {
        case version, id, color, database, targetGames, minGames, settingsModified, studyCards, studyStats,
             limits, practiceMode, cards, summary, lastLine, excludedMoves
    }

    public struct Summary: Codable, Sendable, Equatable {
        public var completion: Double
        public var gapCount: Int
        public var cardCount: Int
        public var matureCount: Int
        public var dueCount: Int
        public var configKey: String
        public var computedAt: Date

        public init(completion: Double, gapCount: Int, cardCount: Int, matureCount: Int, dueCount: Int, configKey: String, computedAt: Date) {
            self.completion = completion
            self.gapCount = gapCount
            self.cardCount = cardCount
            self.matureCount = matureCount
            self.dueCount = dueCount
            self.configKey = configKey
            self.computedAt = computedAt
        }
    }

    public var version = 2
    public var id: UUID
    public var color: Side
    public var database: ExplorerDatabase
    public var targetGames: Int
    public var minGames: Int
    public var settingsModified: Date
    /// Study state of each card (Anki's card table), by position. New cards have none.
    public var studyCards: [EPD: Card]
    /// Cards answered today, for the daily limits.
    public var studyStats: DeckStudyStats?
    /// "This deck" and "Today only" daily limits; nil uses the default preset.
    public var limits: DeckLimits?
    /// Overrides the default practice mode.
    public var practiceMode: PracticeMode?
    /// Version 1 cards (own FSRS-5 scheduler); converted by `decode`.
    var cards: [EPD: LegacyCard]?
    public var summary: Summary?
    /// Last position the user looked at, as UCI moves from the start.
    public var lastLine: [String]?
    /// Opponent moves (UCI) not to cover, by the position before them. A setting: merged
    /// with the others by `settingsModified`.
    public var excludedMoves: [EPD: [String]]?

    public init(id: UUID = UUID(), color: Side, database: ExplorerDatabase = .defaultLichess,
                targetGames: Int = 500, minGames: Int = 25) {
        self.id = id
        self.color = color
        self.database = database
        self.targetGames = targetGames
        self.minGames = minGames
        self.settingsModified = .now
        self.studyCards = [:]
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        color = try c.decode(Side.self, forKey: .color)
        database = try c.decode(ExplorerDatabase.self, forKey: .database)
        targetGames = try c.decode(Int.self, forKey: .targetGames)
        minGames = try c.decode(Int.self, forKey: .minGames)
        settingsModified = try c.decode(Date.self, forKey: .settingsModified)
        studyCards = try c.decodeIfPresent([EPD: Card].self, forKey: .studyCards) ?? [:]
        studyStats = try c.decodeIfPresent(DeckStudyStats.self, forKey: .studyStats)
        limits = try c.decodeIfPresent(DeckLimits.self, forKey: .limits)
        practiceMode = try c.decodeIfPresent(PracticeMode.self, forKey: .practiceMode)
        cards = try c.decodeIfPresent([EPD: LegacyCard].self, forKey: .cards)
        summary = try c.decodeIfPresent(Summary.self, forKey: .summary)
        lastLine = try c.decodeIfPresent([String].self, forKey: .lastLine)
        excludedMoves = try c.decodeIfPresent([EPD: [String]].self, forKey: .excludedMoves)
    }

    public var coverageSettings: CoverageSettings {
        CoverageSettings(color: color, targetGames: targetGames, minGames: minGames, excluded: (excludedMoves ?? [:]).mapValues(Set.init))
    }

    public var configKey: String { "\(database.cacheKey)|\(targetGames)|\(minGames)|\(color.rawValue)" }

    public func isExcluded(_ uci: String, at epd: EPD) -> Bool {
        excludedMoves?[epd]?.contains(uci) == true
    }

    /// Adds or removes an excluded opponent move.
    public mutating func setExcluded(_ uci: String, at epd: EPD, _ excluded: Bool) {
        var moves = excludedMoves ?? [:]
        var set = Set(moves[epd] ?? [])
        if excluded { set.insert(uci) } else { set.remove(uci) }
        moves[epd] = set.isEmpty ? nil : set.sorted()
        excludedMoves = moves.isEmpty ? nil : moves
        settingsModified = .now
    }

    /// Merges a version written elsewhere: cards by latest review, settings by latest change,
    /// today's study counts by the larger.
    public func merged(with other: Sidecar) -> Sidecar {
        var result = settingsModified >= other.settingsModified ? self : other
        var cards = studyCards
        for (epd, card) in other.studyCards {
            if let mine = cards[epd], (mine.lastReviewTime ?? 0) >= (card.lastReviewTime ?? 0) { continue }
            cards[epd] = card
        }
        result.studyCards = cards
        switch (studyStats, other.studyStats) {
        case let (a?, b?): result.studyStats = a.merged(with: b)
        case let (a, b): result.studyStats = a ?? b
        }
        return result
    }

    /// Converts version 1 cards to Anki cards.
    mutating func migrateLegacyCards(timing: SchedTiming) {
        guard let legacy = cards else { return }
        for (epd, old) in legacy where studyCards[epd] == nil {
            studyCards[epd] = old.converted(epd: epd, timing: timing)
        }
        cards = nil
        version = 2
    }

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static func decode(_ data: Data) throws -> Sidecar {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: Self.dateStyle) { return date }
            return try Date(text, strategy: .iso8601)
        }
        var sidecar = try decoder.decode(Sidecar.self, from: data)
        sidecar.migrateLegacyCards(timing: SchedTiming())
        return sidecar
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Self.dateStyle))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// A version 1 card, scheduled by the app's own FSRS-5 code.
struct LegacyCard: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable { case learning, review, relearning }

    var stability: Double
    var difficulty: Double
    var due: Date
    var lastReview: Date
    var reps: Int
    var lapses: Int
    var phase: Phase

    /// Review cards keep their memory and due day (as Anki does when parameters change);
    /// learning cards restart at the first step, due now.
    func converted(epd: EPD, timing: SchedTiming) -> Card {
        var card = Card(id: Card.id(for: epd), position: 0, added: Int64(lastReview.timeIntervalSince1970))
        card.reps = reps
        card.lapses = lapses
        card.easeFactor = 2500
        card.memory = MemoryState(stability: stability, difficulty: difficulty)
        card.lastReviewTime = Int64(lastReview.timeIntervalSince1970)
        let dueDay = timing.daysElapsed + Int(((due.timeIntervalSince1970 - TimeInterval(timing.dayStart)) / 86_400).rounded(.down))
        switch phase {
        case .review:
            card.ctype = .review
            card.queue = .review
            card.interval = max(1, Int((due.timeIntervalSince(lastReview) / 86_400).rounded()))
            card.due = Int64(dueDay)
        case .learning, .relearning:
            card.ctype = phase == .learning ? .learn : .relearn
            card.queue = .learn
            card.interval = phase == .learning ? 0 : 1
            card.remainingSteps = phase == .learning ? 2 : 1
            card.due = timing.now
        }
        return card
    }
}
