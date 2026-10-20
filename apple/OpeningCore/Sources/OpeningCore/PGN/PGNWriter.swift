import Foundation

/// Writes PGN games with variations, comments and NAGs, wrapped at 80 columns.
public enum PGNWriter {
    public static func write(_ games: [PGNGame]) -> String {
        games.map(write).joined(separator: "\n\n") + "\n"
    }

    public static func write(_ game: PGNGame) -> String {
        var out = ""
        for tag in game.tags {
            let value = tag.value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            out += "[\(tag.name) \"\(value)\"]\n"
        }
        if !game.tags.isEmpty { out += "\n" }

        var tokens: [String] = game.comments.map { "{ \($0) }" }
        let startPly = startPly(fen: game.startFEN)
        writeLine(game.moves, ply: startPly, forceNumber: true, into: &tokens)
        tokens.append(game.result)
        out += wrap(tokens)
        return out
    }

    /// Ply index (0 = white's first move) of the first move after `fen`.
    static func startPly(fen: String?) -> Int {
        guard let fen else { return 0 }
        let fields = fen.split(separator: " ")
        let black = fields.count > 1 && fields[1] == "b"
        let fullmove = fields.count > 5 ? Int(fields[5]) ?? 1 : 1
        return (max(fullmove, 1) - 1) * 2 + (black ? 1 : 0)
    }

    /// Writes `alternatives[0]` with `alternatives[1...]` as variations, then continues the main line.
    private static func writeLine(_ alternatives: [PGNMove], ply: Int, forceNumber: Bool, into tokens: inout [String]) {
        guard let main = alternatives.first else { return }
        var needsNumber = forceNumber
        writeMove(main, ply: ply, forceNumber: needsNumber, into: &tokens)
        needsNumber = !main.comments.isEmpty

        for variation in alternatives.dropFirst() {
            var inner: [String] = []
            writeMove(variation, ply: ply, forceNumber: true, into: &inner)
            writeLine(variation.children, ply: ply + 1, forceNumber: !variation.comments.isEmpty, into: &inner)
            if let first = inner.first {
                inner[0] = "(" + first
                inner[inner.count - 1] += ")"
            }
            tokens.append(contentsOf: inner)
            needsNumber = true
        }
        writeLine(main.children, ply: ply + 1, forceNumber: needsNumber, into: &tokens)
    }

    private static func writeMove(_ move: PGNMove, ply: Int, forceNumber: Bool, into tokens: inout [String]) {
        for comment in move.preComments { tokens.append("{ \(comment) }") }
        let number = ply / 2 + 1
        var text = ""
        if ply % 2 == 0 {
            text = "\(number). "
        } else if forceNumber || !move.preComments.isEmpty {
            text = "\(number)... "
        }
        text += move.san
        var nagTokens: [String] = []
        for nag in move.nags {
            if let symbol = NAG.symbol(for: nag), nagTokens.isEmpty, !text.hasSuffix("!"), !text.hasSuffix("?") {
                text += symbol
            } else {
                nagTokens.append("$\(nag)")
            }
        }
        tokens.append(text)
        tokens.append(contentsOf: nagTokens)
        for comment in move.comments { tokens.append("{ \(comment) }") }
    }

    private static func wrap(_ tokens: [String], width: Int = 80) -> String {
        var lines: [String] = []
        var line = ""
        for token in tokens {
            // Keep move numbers attached to their move: tokens like "12. e4" contain one space.
            if line.isEmpty {
                line = token
            } else if line.count + 1 + token.count <= width {
                line += " " + token
            } else {
                lines.append(line)
                line = token
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}
