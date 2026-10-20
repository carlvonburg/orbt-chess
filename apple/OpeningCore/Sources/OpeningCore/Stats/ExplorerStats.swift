import Foundation

public struct ExplorerMove: Codable, Sendable, Hashable {
    /// Standard UCI (castling as king two squares), normalized when decoded.
    public var uci: String
    public var san: String
    public var white: Int
    public var draws: Int
    public var black: Int
    public var averageRating: Int?

    public init(uci: String, san: String, white: Int, draws: Int, black: Int, averageRating: Int? = nil) {
        self.uci = uci
        self.san = san
        self.white = white
        self.draws = draws
        self.black = black
        self.averageRating = averageRating
    }

    public var games: Int { white + draws + black }

    /// Score for `side` in 0...1 (wins + half the draws).
    public func score(for side: Side) -> Double {
        guard games > 0 else { return 0.5 }
        let wins = side == .white ? white : black
        return (Double(wins) + Double(draws) / 2) / Double(games)
    }
}

public struct OpeningName: Codable, Sendable, Hashable {
    public var eco: String
    public var name: String

    public init(eco: String, name: String) {
        self.eco = eco
        self.name = name
    }
}

/// Explorer statistics for one position and one database.
public struct ExplorerStats: Codable, Sendable, Hashable {
    public var white: Int
    public var draws: Int
    public var black: Int
    public var moves: [ExplorerMove]
    public var opening: OpeningName?

    public init(white: Int, draws: Int, black: Int, moves: [ExplorerMove], opening: OpeningName? = nil) {
        self.white = white
        self.draws = draws
        self.black = black
        self.moves = moves
        self.opening = opening
    }

    public var total: Int { white + draws + black }

    /// Share of games in this position that continued with `uci` (move games / position games).
    /// Uses the move's own counts, so transpositions into the child do not inflate it.
    public func share(of uci: String) -> Double {
        guard total > 0, let move = moves.first(where: { $0.uci == uci }) else { return 0 }
        return Double(move.games) / Double(total)
    }

    public func move(_ uci: String) -> ExplorerMove? {
        moves.first { $0.uci == uci }
    }

    /// Converts explorer UCI (which may use king-takes-rook castling) into standard UCI
    /// and fixes SAN, by replaying each move on `position`.
    public func normalized(for position: ChessPosition) -> ExplorerStats {
        var copy = self
        copy.moves = moves.map { move in
            guard let (played, _) = position.play(uci: move.uci) else { return move }
            var m = move
            m.uci = played.uci
            m.san = played.san
            return m
        }
        return copy
    }
}

public enum ExplorerSpeed: String, Codable, Sendable, CaseIterable, Hashable {
    case ultraBullet, bullet, blitz, rapid, classical, correspondence

    public var title: String {
        switch self {
        case .ultraBullet: "UltraBullet"
        case .bullet: "Bullet"
        case .blitz: "Blitz"
        case .rapid: "Rapid"
        case .classical: "Classical"
        case .correspondence: "Correspondence"
        }
    }
}

/// Which explorer database a repertoire measures coverage against.
public enum ExplorerDatabase: Codable, Sendable, Hashable {
    case masters
    /// `ratings` are Lichess bucket lower bounds: 0, 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2500.
    case lichess(speeds: [ExplorerSpeed], ratings: [Int])

    public static let ratingBuckets = [0, 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2500]
    public static let defaultLichess = ExplorerDatabase.lichess(speeds: [.blitz, .rapid, .classical], ratings: [1600, 1800, 2000])

    /// Stable key for the stats cache.
    public var cacheKey: String {
        switch self {
        case .masters:
            return "masters"
        case let .lichess(speeds, ratings):
            let s = speeds.map(\.rawValue).sorted().joined(separator: ",")
            let r = ratings.sorted().map(String.init).joined(separator: ",")
            return "lichess:\(s):\(r)"
        }
    }

    public var summary: String {
        switch self {
        case .masters:
            return "Masters"
        case let .lichess(speeds, ratings):
            let s = ExplorerSpeed.allCases.filter(speeds.contains).map(\.title).joined(separator: ", ")
            let sorted = ratings.sorted()
            guard let low = sorted.first, let high = sorted.last else { return "Lichess · \(s)" }
            let next = Self.ratingBuckets.first { $0 > high }
            let range = next.map { "\(low)–\($0 - 1)" } ?? "\(low)+"
            return "Lichess \(range) · \(s)"
        }
    }

    /// Query items for the explorer endpoint.
    public var queryItems: [URLQueryItem] {
        switch self {
        case .masters:
            return []
        case let .lichess(speeds, ratings):
            return [
                URLQueryItem(name: "speeds", value: speeds.map(\.rawValue).joined(separator: ",")),
                URLQueryItem(name: "ratings", value: ratings.sorted().map(String.init).joined(separator: ",")),
            ]
        }
    }

    public var path: String {
        switch self {
        case .masters: "masters"
        case .lichess: "lichess"
        }
    }

    /// How long cached stats stay fresh. Indefinitely for now, for both.
    public var maxAge: TimeInterval { .infinity }
}
