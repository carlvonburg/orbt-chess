import Foundation

/// Parses PGN text with any number of games, `{}` and `;` comments, nested variations,
/// NAGs and `!?`-style glyphs. Moves are not validated here; see `RepertoireTree`.
public enum PGNParser {
    public static func parse(_ text: String) -> [PGNGame] {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        return parser.parseGames()
    }
}

private final class MoveBuilder {
    var san: String
    var nags: [Int] = []
    var preComments: [String] = []
    var comments: [String] = []
    var children: [MoveBuilder] = []
    weak var parent: MoveBuilder?

    init(san: String, parent: MoveBuilder?) {
        self.san = san
        self.parent = parent
    }

    func build() -> PGNMove {
        PGNMove(san: san, nags: nags, preComments: preComments, comments: comments,
                children: children.map { $0.build() })
    }
}

private struct Parser {
    let scalars: [Unicode.Scalar]
    var i = 0

    init(scalars: [Unicode.Scalar]) { self.scalars = scalars }

    private var atEnd: Bool { i >= scalars.count }
    private var current: Unicode.Scalar { scalars[i] }

    mutating func parseGames() -> [PGNGame] {
        var games: [PGNGame] = []
        while true {
            skipWhitespace()
            if atEnd { break }
            let before = i
            if let game = parseGame() { games.append(game) }
            if i == before { i += 1 }  // never loop on garbage
        }
        return games
    }

    private mutating func parseGame() -> PGNGame? {
        var game = PGNGame()
        var sawContent = false

        // Tags
        while true {
            skipWhitespace()
            guard !atEnd else { break }
            if current == "%" , atLineStart { skipLine(); continue }
            guard current == "[" else { break }
            if let tag = parseTag() {
                game.tags.append(tag)
                sawContent = true
            }
        }

        // Movetext
        let root = MoveBuilder(san: "", parent: nil)
        var cursor = root
        var stack: [MoveBuilder] = []
        var pendingPre: [String] = []

        loop: while true {
            skipWhitespace()
            guard !atEnd else { break }
            let c = current
            switch c {
            case "[":
                // Next game starts without a result token.
                if stack.isEmpty { break loop }
                i += 1
            case "%" where atLineStart:
                skipLine()
            case "{":
                let comment = readBraceComment()
                sawContent = true
                attach(comment: comment, cursor: cursor, root: root, pendingPre: &pendingPre)
            case ";":
                let comment = readLineComment()
                sawContent = true
                attach(comment: comment, cursor: cursor, root: root, pendingPre: &pendingPre)
            case "(":
                i += 1
                stack.append(cursor)
                cursor = cursor.parent ?? root
                // A comment directly after "(" belongs before the first move of the variation.
                pendingPre = []
                variationJustOpened = true
            case ")":
                i += 1
                if let top = stack.popLast() { cursor = top }
                pendingPre = []
                variationJustOpened = false
            case "$":
                i += 1
                let digits = readWhile { $0.properties.numericType != nil }
                if let n = Int(digits), cursor !== root { cursor.nags.append(n) }
            case "*":
                i += 1
                game.result = "*"
                if stack.isEmpty { break loop }
            default:
                let token = readToken()
                guard !token.isEmpty else { i += 1; continue }
                if ["1-0", "0-1", "1/2-1/2", "½-½"].contains(token) {
                    game.result = token == "½-½" ? "1/2-1/2" : token
                    if stack.isEmpty { break loop }
                    continue
                }
                if let move = parseMoveToken(token) {
                    sawContent = true
                    if move.san.isEmpty {
                        if let nag = move.nag, cursor !== root { cursor.nags.append(nag) }
                        continue
                    }
                    let node = MoveBuilder(san: move.san, parent: cursor)
                    if let nag = move.nag { node.nags.append(nag) }
                    node.preComments = pendingPre
                    pendingPre = []
                    variationJustOpened = false
                    cursor.children.append(node)
                    cursor = node
                }
            }
        }

        game.comments = root.comments
        variationJustOpened = false
        game.moves = root.children.map { $0.build() }
        return sawContent ? game : nil
    }

    private var variationJustOpened = false

    private mutating func attach(comment: String, cursor: MoveBuilder, root: MoveBuilder, pendingPre: inout [String]) {
        if variationJustOpened {
            pendingPre.append(comment)
        } else if cursor === root {
            root.comments.append(comment)
        } else {
            cursor.comments.append(comment)
        }
    }

    private var atLineStart: Bool {
        i == 0 || scalars[i - 1] == "\n" || scalars[i - 1] == "\r"
    }

    private mutating func skipWhitespace() {
        while !atEnd, current.properties.isWhitespace || current == "\u{FEFF}" { i += 1 }
    }

    private mutating func skipLine() {
        while !atEnd, current != "\n" { i += 1 }
    }

    private mutating func readWhile(_ predicate: (Unicode.Scalar) -> Bool) -> String {
        var s = String.UnicodeScalarView()
        while !atEnd, predicate(current) {
            s.append(current)
            i += 1
        }
        return String(s)
    }

    private mutating func readToken() -> String {
        readWhile { c in
            !c.properties.isWhitespace && !"{}();[]$".unicodeScalars.contains(c)
        }
    }

    private mutating func readBraceComment() -> String {
        i += 1
        let body = readWhile { $0 != "}" }
        if !atEnd { i += 1 }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func readLineComment() -> String {
        i += 1
        let body = readWhile { $0 != "\n" }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func parseTag() -> PGNTag? {
        i += 1  // [
        skipWhitespace()
        let name = readWhile { !$0.properties.isWhitespace && $0 != "]" && $0 != "\"" }
        skipWhitespace()
        var value = ""
        if !atEnd, current == "\"" {
            i += 1
            var s = String.UnicodeScalarView()
            while !atEnd, current != "\"" {
                if current == "\\", i + 1 < scalars.count {
                    i += 1
                }
                s.append(current)
                i += 1
            }
            if !atEnd { i += 1 }
            value = String(s)
        }
        while !atEnd, current != "]", current != "\n" { i += 1 }
        if !atEnd, current == "]" { i += 1 }
        return name.isEmpty ? nil : PGNTag(name, value)
    }

    /// Strips move numbers ("12.", "12...", "12.e4") and glyphs. Returns san "" for a lone glyph.
    private func parseMoveToken(_ token: String) -> (san: String, nag: Int?)? {
        var t = Substring(token)
        if t.hasPrefix("0-0") {
            t = Substring(t.replacingOccurrences(of: "0", with: "O"))
        }
        // Move number prefix
        let digits = t.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = t.dropFirst(digits.count)
            if afterDigits.first == "." {
                t = afterDigits.drop { $0 == "." }
            } else if afterDigits.isEmpty {
                return nil  // a bare number
            }
        }
        t = t.drop { $0 == "." }
        guard !t.isEmpty else { return nil }
        var glyph = ""
        while let last = t.last, "!?".contains(last) {
            glyph = String(last) + glyph
            t = t.dropLast()
        }
        let nag = NAG.glyphs[glyph]
        let san = String(t)
        if san == "--" || san == "Z0" { return nil }  // null moves are not supported
        if !san.isEmpty, !(san.first!.isLetter) { return nil }  // "+-", "=", "∞" evaluation symbols
        return (san, nag)
    }
}
