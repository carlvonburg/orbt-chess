import Foundation

/// Everything about a repertoire that is not moves: stored next to the PGN as
/// `<Name>.otrep.json` so the PGN stays clean for other chess programs.
public struct Sidecar: Codable, Sendable, Equatable {
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

    public var version = 1
    public var id: UUID
    public var color: Side
    public var database: ExplorerDatabase
    public var targetGames: Int
    public var minGames: Int
    public var settingsModified: Date
    public var cards: [EPD: CardState]
    public var summary: Summary?
    /// Last position the user looked at, as UCI moves from the start.
    public var lastLine: [String]?

    public init(id: UUID = UUID(), color: Side, database: ExplorerDatabase = .defaultLichess,
                targetGames: Int = 500, minGames: Int = 25) {
        self.id = id
        self.color = color
        self.database = database
        self.targetGames = targetGames
        self.minGames = minGames
        self.settingsModified = .now
        self.cards = [:]
    }

    public var coverageSettings: CoverageSettings {
        CoverageSettings(color: color, targetGames: targetGames, minGames: minGames)
    }

    public var configKey: String { "\(database.cacheKey)|\(targetGames)|\(minGames)|\(color.rawValue)" }

    /// Merges a version written elsewhere: cards by latest review, settings by latest change.
    public func merged(with other: Sidecar) -> Sidecar {
        var result = settingsModified >= other.settingsModified ? self : other
        var cards = self.cards
        for (epd, card) in other.cards {
            if let mine = cards[epd], mine.lastReview >= card.lastReview { continue }
            cards[epd] = card
        }
        result.cards = cards
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
