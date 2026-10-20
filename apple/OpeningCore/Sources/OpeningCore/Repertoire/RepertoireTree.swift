import Foundation

public typealias NodeID = Int

public struct RepertoireNode: Sendable, Identifiable {
    public let id: NodeID
    public internal(set) var parent: NodeID?
    /// The move that leads to this node; nil for the root.
    public let move: PlayedMove?
    public let fen: String
    public let epd: EPD
    public let ply: Int
    /// `children[0]` is the main continuation.
    public internal(set) var children: [NodeID] = []
    public internal(set) var comments: [String] = []
    public internal(set) var preComments: [String] = []
    public internal(set) var nags: [Int] = []
    /// Indices of the chapters (PGN games) that contain this node.
    public internal(set) var chapters: Set<Int> = []

    public var sideToMove: Side { epd.sideToMove }
    public var position: ChessPosition { ChessPosition(fen: fen)! }

    /// The user's note without embedded commands like `[%cal Ge2e4]`.
    public var note: String {
        comments.map(Comment.text(of:)).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// One PGN game of the file. Games that start from a non-standard position are kept
/// verbatim in `passthrough` and written back unchanged.
public struct Chapter: Sendable {
    public var tags: [PGNTag]
    public var comments: [String]
    public var result: String
    public var passthrough: PGNGame?

    public var name: String {
        tags.first { $0.name == "ChapterName" }?.value
            ?? tags.first { $0.name == "Event" }?.value ?? ""
    }
}

/// A repertoire as one move tree. All PGN games are merged; transpositions are found
/// through the EPD index.
public struct RepertoireTree: Sendable {
    public static let rootID: NodeID = 0

    public private(set) var nodes: [NodeID: RepertoireNode]
    public private(set) var chapters: [Chapter]
    public private(set) var epdIndex: [EPD: [NodeID]] = [:]
    /// Moves that could not be played when loading (illegal or unreadable SAN).
    public private(set) var loadWarnings: [String] = []
    /// Positions whose PGN lines were merged into another node with the same position.
    public private(set) var mergedTranspositions = 0
    private var nextID: NodeID = 1

    public init(startFEN: String = ChessPosition.startFEN) {
        let pos = ChessPosition(fen: startFEN) ?? .start
        let root = RepertoireNode(id: Self.rootID, parent: nil, move: nil, fen: pos.fen, epd: pos.epd,
                                  ply: PGNWriter.startPly(fen: startFEN == ChessPosition.startFEN ? nil : startFEN))
        nodes = [Self.rootID: root]
        chapters = []
        epdIndex = [root.epd: [Self.rootID]]
    }

    public var root: RepertoireNode { nodes[Self.rootID]! }
    public subscript(id: NodeID) -> RepertoireNode? { nodes[id] }
    public var count: Int { nodes.count }

    // MARK: Queries

    /// Node ids from the root to `id`, inclusive.
    public func path(to id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var cursor: NodeID? = id
        while let c = cursor, let node = nodes[c] {
            result.append(c)
            cursor = node.parent
        }
        return result.reversed()
    }

    public func moves(to id: NodeID) -> [PlayedMove] {
        path(to: id).compactMap { nodes[$0]?.move }
    }

    public func child(of id: NodeID, uci: String) -> NodeID? {
        nodes[id]?.children.first { nodes[$0]?.move?.uci == uci }
    }

    public func child(of id: NodeID, san: String) -> NodeID? {
        guard let children = nodes[id]?.children, !children.isEmpty else { return nil }
        if let exact = children.first(where: { nodes[$0]?.move?.san == san }) { return exact }
        let wanted = SAN.loose(san)
        return children.first { nodes[$0].map { SAN.loose($0.move?.san ?? "") } == wanted }
    }

    /// Follows a list of UCI moves from the root; returns nil if any is missing.
    public func node(followingUCI moves: [String]) -> NodeID? {
        var cursor = Self.rootID
        for uci in moves {
            guard let next = child(of: cursor, uci: uci) else { return nil }
            cursor = next
        }
        return cursor
    }

    /// Depth-first order, parents before children.
    public func subtree(of id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var stack = [id]
        while let n = stack.popLast() {
            result.append(n)
            if let node = nodes[n] { stack.append(contentsOf: node.children.reversed()) }
        }
        return result
    }

    /// For a node without moves: the node with the same position that holds its lines
    /// (the first one that has moves). Never an ancestor, so following it cannot loop.
    public func transpositionTarget(of id: NodeID) -> NodeID? {
        transpositionTarget(of: id, chapter: nil)
    }

    func transpositionTarget(of id: NodeID, chapter: Int?) -> NodeID? {
        guard let node = nodes[id], node.children.isEmpty, let candidates = epdIndex[node.epd],
              candidates.count > 1 else { return nil }
        return candidates.lazy.filter { candidate in
            guard candidate != id, let c = self.nodes[candidate], !c.children.isEmpty else { return false }
            // Moves are written per chapter, so lines only move to a node of the same chapter.
            if let chapter, !c.chapters.contains(chapter) { return false }
            return !self.isAncestor(candidate, of: id)
        }.min()
    }

    public func isAncestor(_ a: NodeID, of b: NodeID) -> Bool {
        var cursor = nodes[b]?.parent
        while let c = cursor {
            if c == a { return true }
            cursor = nodes[c]?.parent
        }
        return false
    }

    /// Leaves under `id` (lines ending there).
    public func leaves(under id: NodeID) -> [NodeID] {
        subtree(of: id).filter { nodes[$0]?.children.isEmpty == true }
    }

    // MARK: Edits

    /// Adds a move after `parent`, reusing an existing child with the same move.
    @discardableResult
    public mutating func addMove(_ uci: String, after parent: NodeID) -> NodeID? {
        if let existing = child(of: parent, uci: uci) { return existing }
        guard let parentNode = nodes[parent],
              let (move, next) = parentNode.position.play(uci: uci) else { return nil }
        if let existing = child(of: parent, uci: move.uci) { return existing }
        return insert(move: move, position: next, after: parent, chapters: [defaultChapter(for: parentNode)])
    }

    @discardableResult
    public mutating func addMove(san: String, after parent: NodeID) -> NodeID? {
        if let existing = child(of: parent, san: san) { return existing }
        guard let parentNode = nodes[parent],
              let (move, next) = parentNode.position.play(san: san) else { return nil }
        if let existing = child(of: parent, uci: move.uci) { return existing }
        return insert(move: move, position: next, after: parent, chapters: [defaultChapter(for: parentNode)])
    }

    /// Adds a sequence of moves; returns the last node.
    @discardableResult
    public mutating func addLine(_ ucis: [String], after start: NodeID) -> NodeID? {
        var cursor = start
        for uci in ucis {
            guard let next = addMove(uci, after: cursor) else { return nil }
            cursor = next
        }
        return cursor
    }

    /// Removes the node and everything below it. The root cannot be deleted.
    public mutating func delete(_ id: NodeID) {
        guard id != Self.rootID, let node = nodes[id], let parent = node.parent else { return }
        for n in subtree(of: id) {
            if let removed = nodes.removeValue(forKey: n) {
                epdIndex[removed.epd]?.removeAll { $0 == n }
                if epdIndex[removed.epd]?.isEmpty == true { epdIndex[removed.epd] = nil }
            }
        }
        nodes[parent]?.children.removeAll { $0 == id }
    }

    /// Makes `id` the main continuation of its parent.
    public mutating func promote(_ id: NodeID) {
        guard let parent = nodes[id]?.parent, var children = nodes[parent]?.children,
              let index = children.firstIndex(of: id), index > 0 else { return }
        children.remove(at: index)
        children.insert(id, at: 0)
        nodes[parent]?.children = children
    }

    /// Replaces the user's note and keeps embedded commands such as arrows.
    public mutating func setNote(_ text: String, for id: NodeID) {
        guard let node = nodes[id] else { return }
        let commands = node.comments.flatMap(Comment.commands(in:))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = (commands + (trimmed.isEmpty ? [] : [trimmed])).joined(separator: " ")
        nodes[id]?.comments = combined.isEmpty ? [] : [combined]
    }

    public mutating func setChapterTag(_ index: Int, _ name: String, _ value: String) {
        if chapters.isEmpty {
            chapters = [Chapter(tags: Self.defaultTags(), comments: [], result: "*")]
            nodes[Self.rootID]?.chapters = [0]
        }
        guard chapters.indices.contains(index) else { return }
        if let i = chapters[index].tags.firstIndex(where: { $0.name == name }) {
            chapters[index].tags[i].value = value
        } else {
            chapters[index].tags.insert(PGNTag(name, value), at: 0)
        }
    }

    // MARK: PGN

    /// Builds a tree from PGN games. Games from the standard position are merged into one tree.
    public init(games: [PGNGame]) {
        self.init()
        for game in games { appendChapter(game) }
        if chapters.isEmpty { chapters = [Chapter(tags: Self.defaultTags(), comments: [], result: "*")] }
        nodes[Self.rootID]?.chapters = Set(chapters.indices.filter { chapters[$0].passthrough == nil })
    }

    public init(pgn: String) {
        self.init(games: PGNParser.parse(pgn))
    }

    public static func defaultTags(event: String = "Repertoire") -> [PGNTag] {
        [PGNTag("Event", event), PGNTag("Site", "?"), PGNTag("Result", "*")]
    }

    private mutating func appendChapter(_ game: PGNGame) {
        let index = chapters.count
        if let fen = game.startFEN, let pos = ChessPosition(fen: fen), pos.epd != root.epd {
            chapters.append(Chapter(tags: game.tags, comments: game.comments, result: game.result, passthrough: game))
            return
        }
        chapters.append(Chapter(tags: game.tags, comments: game.comments, result: game.result, passthrough: nil))
        nodes[Self.rootID]?.chapters.insert(index)
        merge(game.moves, at: Self.rootID, chapter: index)
    }

    /// Merges PGN moves (with variations) below `id`. Returns the number of new nodes.
    @discardableResult
    public mutating func merge(_ moves: [PGNMove], at id: NodeID, chapter: Int? = nil) -> Int {
        let before = nodes.count
        let chapter = chapter ?? nodes[id].map(defaultChapter(for:)) ?? 0
        var stack: [(PGNMove, NodeID)] = moves.reversed().map { ($0, id) }
        // Boards of nodes created here, so their children are played without re-parsing the FEN.
        var boards: [NodeID: ChessPosition] = [:]
        while let (pgnMove, parent) = stack.popLast() {
            guard let parentNode = nodes[parent] else { continue }
            var target: NodeID
            if let existing = child(of: parent, san: pgnMove.san) {
                target = existing
            } else if let (move, next) = (boards[parent] ?? parentNode.position).play(san: pgnMove.san) {
                if let existing = child(of: parent, uci: move.uci) {
                    target = existing
                } else {
                    target = insert(move: move, position: next, after: parent, chapters: [])
                    if !pgnMove.children.isEmpty { boards[target] = next }
                }
            } else {
                let line = self.moves(to: parent).map(\.san).joined(separator: " ")
                loadWarnings.append("Illegal move \(pgnMove.san) after \(line.isEmpty ? "start" : line)")
                continue
            }
            nodes[target]?.chapters.insert(chapter)
            appendUnique(pgnMove.comments, to: \.comments, of: target)
            appendUnique(pgnMove.preComments, to: \.preComments, of: target)
            for nag in pgnMove.nags where nodes[target]?.nags.contains(nag) == false {
                nodes[target]?.nags.append(nag)
            }
            // A position whose lines are already stored elsewhere stays a leaf here: its moves
            // are merged into that node, so each position's continuation is stored once.
            // (Exports like Chessbook's repeat the whole subtree under every move order.)
            let continuation = pgnMove.children.isEmpty ? target
                : transpositionTarget(of: target, chapter: chapter) ?? target
            if continuation != target { mergedTranspositions += 1 }
            stack.append(contentsOf: pgnMove.children.reversed().map { ($0, continuation) })
        }
        return nodes.count - before
    }

    /// Union of both trees (used when the file changed elsewhere). Chapters are matched by index.
    @discardableResult
    public mutating func merge(tree other: RepertoireTree) -> Int {
        var added = 0
        for (index, game) in other.pgnGames().enumerated() {
            if index < chapters.count, chapters[index].passthrough == nil, other.chapters[index].passthrough == nil {
                added += merge(game.moves, at: Self.rootID, chapter: index)
            } else if index >= chapters.count {
                let before = nodes.count
                appendChapter(game)
                nodes[Self.rootID]?.chapters = Set(chapters.indices.filter { chapters[$0].passthrough == nil })
                added += nodes.count - before
            }
        }
        return added
    }

    /// Writes all chapters back as PGN games.
    public func pgnGames() -> [PGNGame] {
        chapters.indices.map { index in
            let chapter = chapters[index]
            if let passthrough = chapter.passthrough { return passthrough }
            return PGNGame(tags: chapter.tags, comments: chapter.comments,
                           moves: pgnMoves(below: Self.rootID, chapter: index), result: chapter.result)
        }
    }

    public func pgnText() -> String {
        PGNWriter.write(pgnGames())
    }

    /// Moves below `id` as PGN, restricted to `chapter` if given.
    public func pgnMoves(below id: NodeID, chapter: Int? = nil) -> [PGNMove] {
        guard let node = nodes[id] else { return [] }
        return node.children.compactMap { childID -> PGNMove? in
            guard let child = nodes[childID], let move = child.move else { return nil }
            if let chapter, !child.chapters.contains(chapter) { return nil }
            return PGNMove(san: move.san, nags: child.nags, preComments: child.preComments,
                           comments: child.comments, children: pgnMoves(below: childID, chapter: chapter))
        }
    }

    // MARK: Private

    private func defaultChapter(for parent: RepertoireNode) -> Int {
        parent.chapters.min() ?? chapters.firstIndex { $0.passthrough == nil } ?? 0
    }

    private mutating func insert(move: PlayedMove, position: ChessPosition, after parent: NodeID, chapters: Set<Int>) -> NodeID {
        if self.chapters.isEmpty {
            self.chapters = [Chapter(tags: Self.defaultTags(), comments: [], result: "*")]
            nodes[Self.rootID]?.chapters = [0]
        }
        let id = nextID
        nextID += 1
        let parentPly = nodes[parent]?.ply ?? 0
        let node = RepertoireNode(id: id, parent: parent, move: move, fen: position.fen, epd: position.epd,
                                  ply: parentPly + 1, chapters: chapters)
        nodes[id] = node
        nodes[parent]?.children.append(id)
        epdIndex[node.epd, default: []].append(id)
        return id
    }

    private mutating func appendUnique(_ items: [String], to keyPath: WritableKeyPath<RepertoireNode, [String]>, of id: NodeID) {
        for item in items where nodes[id]?[keyPath: keyPath].contains(item) == false {
            nodes[id]?[keyPath: keyPath].append(item)
        }
    }
}

/// Helpers for PGN comments with embedded commands like `[%cal Ge2e4,Rd7d5]`.
public enum Comment {
    static let commandPattern = try! NSRegularExpression(pattern: "\\[%[^\\]]*\\]")

    public static func commands(in comment: String) -> [String] {
        let range = NSRange(comment.startIndex..., in: comment)
        return commandPattern.matches(in: comment, range: range).compactMap {
            Range($0.range, in: comment).map { String(comment[$0]) }
        }
    }

    public static func text(of comment: String) -> String {
        let range = NSRange(comment.startIndex..., in: comment)
        return commandPattern.stringByReplacingMatches(in: comment, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
