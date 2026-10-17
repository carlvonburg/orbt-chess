/// Position key: FEN without move counters. The en-passant square is kept only when an
/// en-passant capture is legal, so transpositions are not split by irrelevant ep squares.
/// Used for the stats cache, transpositions, training cards and cloud-eval caching.
public struct EPD: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    init(fen: String, legalEnPassant: Bool) {
        let fields = fen.split(separator: " ").prefix(4).map(String.init)
        var parts = fields
        if parts.count == 4, !legalEnPassant { parts[3] = "-" }
        rawValue = parts.joined(separator: " ")
    }

    /// FEN to send to Lichess: EPD with neutral move counters.
    public var queryFEN: String { rawValue + " 0 1" }
    public var sideToMove: Side { rawValue.split(separator: " ").dropFirst().first == "b" ? .black : .white }
    public var description: String { rawValue }

    public static func < (lhs: EPD, rhs: EPD) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
