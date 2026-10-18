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
    /// The letter after the board field. Read in place: card walks call this for every node.
    public var sideToMove: Side {
        let bytes = rawValue.utf8
        guard let space = bytes.firstIndex(of: UInt8(ascii: " ")) else { return .white }
        let side = bytes.index(after: space)
        return side < bytes.endIndex && bytes[side] == UInt8(ascii: "b") ? .black : .white
    }
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

extension EPD: CodingKeyRepresentable {
    public var codingKey: CodingKey { Key(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { rawValue = codingKey.stringValue }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
