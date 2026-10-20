import ChessKit
import Foundation

public enum Side: String, Codable, Sendable, Hashable, CaseIterable {
    case white, black

    public var opposite: Side { self == .white ? .black : .white }

    init(_ color: Piece.Color) { self = color == .white ? .white : .black }
}

/// A square in algebraic notation ("e4"), stored as 0...63 with a1 = 0, h8 = 63.
public struct BoardSquare: Hashable, Sendable, Codable, CustomStringConvertible {
    public let index: Int

    public init(index: Int) { self.index = index }
    public init(file: Int, rank: Int) { index = rank * 8 + file }
    public init?(_ notation: some StringProtocol) {
        let chars = Array(notation.utf8)
        guard chars.count == 2,
              (97...104).contains(chars[0]), (49...56).contains(chars[1]) else { return nil }
        index = Int(chars[1] - 49) * 8 + Int(chars[0] - 97)
    }

    public var file: Int { index % 8 }
    public var rank: Int { index / 8 }
    public var isLight: Bool { (file + rank) % 2 == 1 }
    public var description: String {
        String(UnicodeScalar(UInt8(97 + file))) + String(rank + 1)
    }

    var kit: Square { Square(description) }
}

public enum PieceKind: String, Sendable, Codable, CaseIterable {
    case pawn = "p", knight = "n", bishop = "b", rook = "r", queen = "q", king = "k"

    init(_ kind: Piece.Kind) {
        switch kind {
        case .pawn: self = .pawn
        case .knight: self = .knight
        case .bishop: self = .bishop
        case .rook: self = .rook
        case .queen: self = .queen
        case .king: self = .king
        }
    }

    var kit: Piece.Kind {
        switch self {
        case .pawn: .pawn
        case .knight: .knight
        case .bishop: .bishop
        case .rook: .rook
        case .queen: .queen
        case .king: .king
        }
    }
}

public struct BoardPiece: Hashable, Sendable {
    public let side: Side
    public let kind: PieceKind
    public let square: BoardSquare
}

/// A move that was played from a position, in both notations.
public struct PlayedMove: Hashable, Sendable, Codable {
    /// SAN including check and mate suffixes, e.g. "Nf3", "exd5", "O-O", "e8=Q+".
    public let san: String
    /// UCI with standard castling notation, e.g. "e1g1", "e7e8q".
    public let uci: String

    public init(san: String, uci: String) {
        self.san = san
        self.uci = uci
    }

    public var from: BoardSquare { BoardSquare(uci.prefix(2))! }
    public var to: BoardSquare { BoardSquare(uci.dropFirst(2).prefix(2))! }
}

/// Immutable chess position with legal-move helpers. Wraps ChessKit.
public struct ChessPosition: Sendable {
    private var board: Board

    public static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    public static let start = ChessPosition(fen: startFEN)!

    public init?(fen: String) {
        guard let position = Position(fen: fen) else { return nil }
        board = Board(position: position)
    }

    private init(board: Board) { self.board = board }

    public var fen: String { board.position.fen }
    public var epd: EPD { EPD(fen: fen, legalEnPassant: hasLegalEnPassant) }
    public var sideToMove: Side { Side(board.position.sideToMove) }
    public var fullmoveNumber: Int { board.position.clock.fullmoves }

    public var pieces: [BoardPiece] {
        board.position.pieces.map {
            BoardPiece(side: Side($0.color), kind: PieceKind($0.kind),
                       square: BoardSquare(index: $0.square.rawValue))
        }
    }

    public func piece(at square: BoardSquare) -> BoardPiece? {
        guard let p = board.position.piece(at: square.kit) else { return nil }
        return BoardPiece(side: Side(p.color), kind: PieceKind(p.kind), square: square)
    }

    public func legalDestinations(from square: BoardSquare) -> [BoardSquare] {
        guard let p = board.position.piece(at: square.kit), Side(p.color) == sideToMove else { return [] }
        return board.legalMoves(forPieceAt: square.kit).map { BoardSquare(index: $0.rawValue) }
    }

    public func isPromotion(from: BoardSquare, to: BoardSquare) -> Bool {
        guard let p = piece(at: from), p.kind == .pawn else { return false }
        return to.rank == 0 || to.rank == 7
    }

    public var isCheckmate: Bool {
        if case .checkmate = board.state { return true }
        return false
    }

    /// Plays a move given as UCI ("e2e4", "e7e8q"). Accepts king-takes-rook castling ("e1h1").
    public func play(uci: String) -> (PlayedMove, ChessPosition)? {
        let chars = Array(uci)
        guard chars.count == 4 || chars.count == 5,
              let from = BoardSquare(String(chars[0...1])),
              var to = BoardSquare(String(chars[2...3])) else { return nil }
        if let p = piece(at: from), p.kind == .king, let target = piece(at: to),
           target.kind == .rook, target.side == p.side {
            // Chess960-style castling as sent by some Lichess endpoints.
            to = BoardSquare(file: to.file > from.file ? 6 : 2, rank: from.rank)
        }
        let promotion = chars.count == 5 ? PieceKind(rawValue: String(chars[4]).lowercased()) : nil
        return play(from: from, to: to, promotion: promotion)
    }

    public func play(from: BoardSquare, to: BoardSquare, promotion: PieceKind? = nil) -> (PlayedMove, ChessPosition)? {
        guard let p = piece(at: from), p.side == sideToMove else { return nil }
        var next = board
        guard var move = next.move(pieceAt: from.kit, to: to.kit) else { return nil }
        if case .promotion(let pending) = next.state {
            let kind = promotion ?? .queen
            guard kind != .pawn, kind != .king else { return nil }
            move = next.completePromotion(of: pending, to: kind.kit)
        }
        let promo = move.promotedPiece.map { PieceKind($0.kind).rawValue } ?? ""
        let uci = from.description + to.description + promo
        return (PlayedMove(san: move.san, uci: uci), ChessPosition(board: next))
    }

    /// Plays a SAN move. Tolerates annotation glyphs, missing or extra check marks and "e.p.".
    public func play(san raw: String) -> (PlayedMove, ChessPosition)? {
        let san = SAN.normalized(raw)
        guard !san.isEmpty else { return nil }
        let candidates = [san, san + "+", san + "#"]
        for candidate in candidates {
            if let move = Move(san: candidate, position: board.position) {
                let promotion = move.promotedPiece.map { PieceKind($0.kind) }
                if let result = play(from: BoardSquare(index: move.start.rawValue),
                                     to: BoardSquare(index: move.end.rawValue),
                                     promotion: promotion),
                   SAN.normalized(result.0.san) == san {
                    return result
                }
            }
        }
        // Fallback: match against all legal moves (handles over-disambiguated SAN like "Ngf3").
        let wanted = SAN.loose(san)
        let legal = legalMoves()
        if let move = legal.first(where: { SAN.loose($0.san) == wanted }) {
            return play(uci: move.uci)
        }
        if let parts = SAN.parts(wanted) {
            let matches = legal.filter { move in
                guard let m = SAN.parts(SAN.loose(move.san)), m.piece == parts.piece,
                      m.destination == parts.destination, m.promotion == parts.promotion else { return false }
                let from = move.from.description
                return parts.disambiguation.allSatisfy { from.contains($0) }
            }
            if matches.count == 1 { return play(uci: matches[0].uci) }
        }
        return nil
    }

    /// All legal moves in this position.
    public func legalMoves() -> [PlayedMove] {
        var result: [PlayedMove] = []
        for p in pieces where p.side == sideToMove {
            for to in legalDestinations(from: p.square) {
                if isPromotion(from: p.square, to: to) {
                    for kind in [PieceKind.queen, .rook, .bishop, .knight] {
                        if let m = play(from: p.square, to: to, promotion: kind) { result.append(m.0) }
                    }
                } else if let m = play(from: p.square, to: to) {
                    result.append(m.0)
                }
            }
        }
        return result
    }

    private var hasLegalEnPassant: Bool {
        let fields = fen.split(separator: " ")
        guard fields.count >= 4, fields[3] != "-", let ep = BoardSquare(fields[3]) else { return false }
        let pawnRank = sideToMove == .white ? 4 : 3
        for df in [-1, 1] {
            let file = ep.file + df
            guard (0...7).contains(file) else { continue }
            let from = BoardSquare(file: file, rank: pawnRank)
            if let p = piece(at: from), p.kind == .pawn, p.side == sideToMove,
               legalDestinations(from: from).contains(ep) {
                return true
            }
        }
        return false
    }
}

public enum SAN {
    /// Strips annotation glyphs, "e.p." and trailing whitespace; keeps check marks.
    public static func normalized(_ san: String) -> String {
        var s = san.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "e.p.", with: "")
        s = s.replacingOccurrences(of: "0-0-0", with: "O-O-O").replacingOccurrences(of: "0-0", with: "O-O")
        while let last = s.last, "!?".contains(last) { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Splits a loose SAN ("Ngf3", "exd5", "e8=Q") into piece letter, disambiguation, destination and promotion.
    static func parts(_ san: String) -> (piece: Character, disambiguation: String, destination: String, promotion: String)? {
        guard !san.hasPrefix("O-O") else { return nil }
        var body = san.replacingOccurrences(of: "x", with: "")
        var promotion = ""
        if let eq = body.firstIndex(of: "=") {
            promotion = String(body[body.index(after: eq)...])
            body = String(body[..<eq])
        }
        guard body.count >= 2 else { return nil }
        let destination = String(body.suffix(2))
        var rest = String(body.dropLast(2))
        var piece: Character = "P"
        if let first = rest.first, first.isUppercase {
            piece = first
            rest.removeFirst()
        }
        return (piece, rest, destination, promotion)
    }

    /// Normalized and without check/mate marks, for comparing moves.
    public static func loose(_ san: String) -> String {
        normalized(san).replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "#", with: "")
    }
}
