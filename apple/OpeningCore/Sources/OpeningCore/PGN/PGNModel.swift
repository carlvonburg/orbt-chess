/// Raw PGN as written in the file, before any move is validated.
public struct PGNTag: Hashable, Sendable, Codable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct PGNMove: Hashable, Sendable {
    public var san: String
    public var nags: [Int] = []
    /// Comments placed before the move, e.g. at the start of a variation.
    public var preComments: [String] = []
    /// Comments placed after the move.
    public var comments: [String] = []
    /// `children[0]` continues this line; the others are variations replacing `children[0]`.
    public var children: [PGNMove] = []

    public init(san: String, nags: [Int] = [], preComments: [String] = [], comments: [String] = [], children: [PGNMove] = []) {
        self.san = san
        self.nags = nags
        self.preComments = preComments
        self.comments = comments
        self.children = children
    }
}

public struct PGNGame: Hashable, Sendable {
    public var tags: [PGNTag] = []
    /// Comments before the first move.
    public var comments: [String] = []
    /// First moves: `moves[0]` is the main line, the others are variations of it.
    public var moves: [PGNMove] = []
    public var result: String = "*"

    public init(tags: [PGNTag] = [], comments: [String] = [], moves: [PGNMove] = [], result: String = "*") {
        self.tags = tags
        self.comments = comments
        self.moves = moves
        self.result = result
    }

    public func tag(_ name: String) -> String? {
        tags.first { $0.name == name }?.value
    }

    public mutating func setTag(_ name: String, _ value: String) {
        if let i = tags.firstIndex(where: { $0.name == name }) {
            tags[i].value = value
        } else {
            tags.append(PGNTag(name, value))
        }
    }

    /// Starting FEN from the SetUp/FEN tags, or nil for the standard position.
    public var startFEN: String? {
        guard let fen = tag("FEN"), !fen.isEmpty else { return nil }
        return fen
    }
}

enum NAG {
    static let glyphs: [String: Int] = ["!": 1, "?": 2, "!!": 3, "??": 4, "!?": 5, "?!": 6]

    static func symbol(for nag: Int) -> String? {
        glyphs.first { $0.value == nag }?.key
    }
}
