import Foundation

/// Everything about a repertoire that is not moves: stored next to the PGN as
/// `<Name>.otrep.json` so the PGN stays clean for other chess programs.
public struct Sidecar: Codable, Sendable, Equatable {
    enum CodingKeys: String, CodingKey {
        case version, id, color, database, targetGames, minGames, settingsModified, studyCards, studyStats,
             limits, practiceMode, summary, lastLine, excludedMoves
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

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static func decode(_ data: Data) throws -> Sidecar {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: Self.dateStyle) { return date }
            return try Date(text, strategy: .iso8601)
        }
        return try decoder.decode(Sidecar.self, from: data)
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
