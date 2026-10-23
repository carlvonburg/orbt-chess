import OpeningCoreRust
import SwiftUI

struct BoardArrow: Hashable, Identifiable {
    enum Style: Hashable { case mine, opponent, gap, hint, engine }

    let from: BoardSquare
    let to: BoardSquare
    var style: Style
    /// Width as a fraction of a square (0.08...0.3).
    var width: Double = 0.18
    var opacity: Double = 0.85
    var dashed = false

    var id: String { "\(from)\(to)\(style)" }

    init(from: BoardSquare, to: BoardSquare, style: Style, width: Double = 0.18, opacity: Double = 0.85, dashed: Bool = false) {
        self.from = from
        self.to = to
        self.style = style
        self.width = width
        self.opacity = opacity
        self.dashed = dashed
    }

    /// An arrow the core chose.
    init(_ arrow: Arrow) {
        let style: Style = switch arrow.style {
        case .mine: .mine
        case .opponent: .opponent
        case .gap: .gap
        case .hint: .hint
        }
        self.init(from: arrow.from, to: arrow.to, style: style, width: arrow.width, opacity: arrow.opacity, dashed: arrow.dashed)
    }

    func color(_ theme: BoardTheme) -> Color {
        switch style {
        case .mine, .opponent, .hint, .gap: theme.ink
        case .engine: theme.engine
        }
    }
}

/// A mark in the top-right corner of a square: how the move to it was judged.
struct BoardBadge: Equatable {
    enum Kind { case correct, wrong }

    let square: BoardSquare
    let kind: Kind
}

/// Interactive chess board: tap-tap or drag to move, legal-move dots, last-move highlight,
/// promotion picker, arrows and sliding piece animation.
struct BoardView: View {
    let position: ChessPosition
    var orientation: Side = .white
    var lastMove: PlayedMove?
    var arrows: [BoardArrow] = []
    var badge: BoardBadge?
    /// Which side may be moved; nil disables interaction.
    var movableSide: Side?
    var onMove: (BoardSquare, BoardSquare, PieceKind?) -> Void = { _, _, _ in }

    @Environment(\.theme) private var appTheme
    private var theme: BoardTheme { appTheme.board }
    @State private var selected: BoardSquare?
    @State private var dragFrom: BoardSquare?
    @State private var dragLocation: CGPoint?
    @State private var promotion: (from: BoardSquare, to: BoardSquare)?
    @State private var layout = PieceLayout()
    /// A move made by dragging: the piece stays where it was dropped instead of sliding there.
    @State private var drop: Drop?

    private struct Drop {
        let from: BoardSquare
        let to: BoardSquare
        let side: Side
        let fen: String
    }

    /// The drop, once the position shows it played (not when the move was refused).
    private var playedDrop: Drop? {
        guard let drop, drop.fen != position.fen(), position.piece(at: drop.to)?.side == drop.side else { return nil }
        return drop
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let sq = size / 8
            let dropped = playedDrop
            ZStack(alignment: .topLeading) {
                squares(sq: sq)
                coordinates(sq: sq)
                ForEach(layout.pieces) { piece in
                    let isDragged = piece.square == dragFrom && dragLocation != nil
                    // Until the layout catches up with the new position (onChange runs after a frame).
                    let square = dropped?.from == piece.square ? dropped!.to : piece.square
                    Image(piece.assetName)
                        .resizable()
                        .frame(width: sq, height: sq)
                        .position(isDragged ? dragLocation! : center(square, sq: sq))
                        .zIndex(isDragged ? 10 : 1)
                        .allowsHitTesting(false)
                }
                ArrowsView(arrows: arrows, theme: theme, center: { center($0, sq: sq) }, square: sq)
                    .allowsHitTesting(false)
                    .zIndex(5)
                badgeLayer(sq: sq)
                    .zIndex(6)
                if let promotion {
                    promotionPicker(promotion, sq: sq)
                        .zIndex(20)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(boardGesture(sq: sq))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { layout.update(to: position) }
        .onChange(of: position.fen()) {
            selected = nil
            if playedDrop != nil {
                layout.update(to: position)
            } else {
                withAnimation(.easeOut(duration: 0.15)) { layout.update(to: position) }
            }
            drop = nil
        }
        .sensoryFeedback(.impact(weight: .light), trigger: position.fen())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chess board")
    }

    // MARK: Drawing

    private func squares(sq: CGFloat) -> some View {
        let legal = Set(selected.map(position.legalDestinations(from:)) ?? [])
        return Canvas { ctx, _ in
            for index in 0..<64 {
                let square = BoardSquare(index: index)
                let rect = rect(for: square, sq: sq)
                ctx.fill(Path(rect), with: .color(square.isLight ? theme.light : theme.dark))
                if let lastMove, square == lastMove.from || square == lastMove.to {
                    ctx.fill(Path(rect), with: .color(theme.lastMove))
                }
                if square == selected {
                    ctx.fill(Path(rect), with: .color(theme.selected))
                }
                if legal.contains(square) {
                    if position.piece(at: square) != nil {
                        let ring = Path(ellipseIn: rect.insetBy(dx: sq * 0.04, dy: sq * 0.04))
                        ctx.stroke(ring, with: .color(.black.opacity(0.25)), lineWidth: sq * 0.08)
                    } else {
                        let dot = Path(ellipseIn: rect.insetBy(dx: sq * 0.36, dy: sq * 0.36))
                        ctx.fill(dot, with: .color(.black.opacity(0.22)))
                    }
                }
            }
        }
        .frame(width: sq * 8, height: sq * 8)
    }

    private func badgeLayer(sq: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let badge {
                let r = rect(for: badge.square, sq: sq)
                let at = CGPoint(x: r.maxX - sq * 0.2, y: r.minY + sq * 0.2)
                let correct = badge.kind == .correct
                Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, correct ? theme.ink : theme.wrong)
                    .frame(width: sq * 0.38, height: sq * 0.38)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .position(at)
                    // .position fills the board, so scale around the badge, not the board's centre.
                    .transition(.scale(scale: 0.3, anchor: UnitPoint(x: at.x / (sq * 8), y: at.y / (sq * 8)))
                        .combined(with: .opacity))
            }
        }
        .frame(width: sq * 8, height: sq * 8, alignment: .topLeading)
        .animation(.snappy(duration: 0.2), value: badge)
        .allowsHitTesting(false)
    }

    private func coordinates(sq: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<8, id: \.self) { i in
                let file = orientation == .white ? i : 7 - i
                let rank = orientation == .white ? 7 - i : i
                Text(String(UnicodeScalar(UInt8(97 + file))))
                    .font(.system(size: sq * 0.2, weight: .semibold))
                    .foregroundStyle(BoardSquare(file: file, rank: orientation == .white ? 0 : 7).isLight ? theme.dark : theme.light)
                    .position(x: CGFloat(i) * sq + sq * 0.86, y: sq * 7.84)
                Text("\(rank + 1)")
                    .font(.system(size: sq * 0.2, weight: .semibold))
                    .foregroundStyle(BoardSquare(file: orientation == .white ? 0 : 7, rank: rank).isLight ? theme.dark : theme.light)
                    .position(x: sq * 0.12, y: CGFloat(i) * sq + sq * 0.16)
            }
        }
        .allowsHitTesting(false)
    }

    private func promotionPicker(_ move: (from: BoardSquare, to: BoardSquare), sq: CGFloat) -> some View {
        let side = position.sideToMove()
        let kinds: [PieceKind] = [.queen, .knight, .rook, .bishop]
        let c = center(move.to, sq: sq)
        let downward = c.y < sq * 4
        return ZStack {
            Color.black.opacity(0.35)
                .onTapGesture { promotion = nil }
            VStack(spacing: 0) {
                ForEach(downward ? kinds : kinds.reversed(), id: \.self) { kind in
                    Button {
                        let from = move.from, to = move.to
                        promotion = nil
                        selected = nil
                        onMove(from, to, kind)
                    } label: {
                        Image(PieceLayout.assetName(side: side, kind: kind))
                            .resizable()
                            .frame(width: sq, height: sq)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
            .position(x: c.x, y: downward ? c.y + sq * 1.5 : c.y - sq * 1.5)
        }
        .frame(width: sq * 8, height: sq * 8)
    }

    // MARK: Interaction

    private func boardGesture(sq: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard movableSide != nil, promotion == nil else { return }
                if dragFrom == nil {
                    let start = square(at: value.startLocation, sq: sq)
                    if let start, canMove(from: start) { dragFrom = start }
                }
                let distance = hypot(value.translation.width, value.translation.height)
                if dragFrom != nil, distance > 6 {
                    dragLocation = value.location
                    selected = dragFrom
                }
            }
            .onEnded { value in
                defer {
                    dragFrom = nil
                    dragLocation = nil
                }
                guard movableSide != nil, promotion == nil, let target = square(at: value.location, sq: sq) else { return }
                let wasDrag = dragLocation != nil
                if wasDrag, let from = dragFrom {
                    if from != target { attemptMove(from: from, to: target, dragged: true) }
                    return
                }
                // Tap
                if let from = selected, from != target, position.legalDestinations(from: from).contains(target) {
                    attemptMove(from: from, to: target)
                } else if canMove(from: target), selected != target {
                    selected = target
                } else {
                    selected = nil
                }
            }
    }

    private func canMove(from square: BoardSquare) -> Bool {
        guard let movableSide, let piece = position.piece(at: square) else { return false }
        return piece.side == movableSide && piece.side == position.sideToMove()
    }

    private func attemptMove(from: BoardSquare, to: BoardSquare, dragged: Bool = false) {
        guard position.legalDestinations(from: from).contains(to) else {
            selected = canMove(from: to) ? to : nil
            return
        }
        if position.isPromotion(from: from, to: to) {
            promotion = (from, to)
            return
        }
        selected = nil
        if dragged, let side = position.piece(at: from)?.side {
            drop = Drop(from: from, to: to, side: side, fen: position.fen())
        }
        onMove(from, to, nil)
    }

    // MARK: Geometry

    private func rect(for square: BoardSquare, sq: CGFloat) -> CGRect {
        let col = orientation == .white ? square.file : 7 - square.file
        let row = orientation == .white ? 7 - square.rank : square.rank
        return CGRect(x: CGFloat(col) * sq, y: CGFloat(row) * sq, width: sq, height: sq)
    }

    private func center(_ square: BoardSquare, sq: CGFloat) -> CGPoint {
        let r = rect(for: square, sq: sq)
        return CGPoint(x: r.midX, y: r.midY)
    }

    private func square(at point: CGPoint, sq: CGFloat) -> BoardSquare? {
        let col = Int(point.x / sq), row = Int(point.y / sq)
        guard (0...7).contains(col), (0...7).contains(row) else { return nil }
        let file = orientation == .white ? col : 7 - col
        let rank = orientation == .white ? 7 - row : row
        return BoardSquare(file: file, rank: rank)
    }
}

/// Keeps a stable identity per piece across positions so moves slide instead of fading.
struct PieceLayout {
    struct Placed: Identifiable, Hashable {
        let id: Int
        let side: Side
        let kind: PieceKind
        let square: BoardSquare
        var assetName: String { PieceLayout.assetName(side: side, kind: kind) }
    }

    private(set) var pieces: [Placed] = []
    private var nextID = 0

    static func assetName(side: Side, kind: PieceKind) -> String {
        (side == .white ? "w" : "b") + kind.rawValue.uppercased()
    }

    mutating func update(to position: ChessPosition) {
        let new = position.pieces()
        var unmatchedOld = pieces
        var result: [Placed] = []
        var unmatchedNew: [BoardPiece] = []
        for piece in new {
            if let i = unmatchedOld.firstIndex(where: { $0.square == piece.square && $0.side == piece.side && $0.kind == piece.kind }) {
                result.append(unmatchedOld.remove(at: i))
            } else {
                unmatchedNew.append(piece)
            }
        }
        for piece in unmatchedNew {
            let candidates = unmatchedOld.enumerated().filter {
                $0.element.side == piece.side && ($0.element.kind == piece.kind || $0.element.kind == .pawn)
            }
            let best = candidates.min { a, b in
                distance(a.element.square, piece.square) < distance(b.element.square, piece.square)
            }
            if let best {
                unmatchedOld.remove(at: best.offset)
                result.append(Placed(id: best.element.id, side: piece.side, kind: piece.kind, square: piece.square))
            } else {
                result.append(Placed(id: nextID, side: piece.side, kind: piece.kind, square: piece.square))
                nextID += 1
            }
        }
        pieces = result
    }

    private func distance(_ a: BoardSquare, _ b: BoardSquare) -> Int {
        abs(a.file - b.file) + abs(a.rank - b.rank)
    }
}

struct ArrowsView: View {
    let arrows: [BoardArrow]
    let theme: BoardTheme
    let center: (BoardSquare) -> CGPoint
    let square: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            for arrow in arrows {
                let start = center(arrow.from), end = center(arrow.to)
                let dx = end.x - start.x, dy = end.y - start.y
                let length = hypot(dx, dy)
                guard length > 0 else { continue }
                let ux = dx / length, uy = dy / length
                let width = square * arrow.width
                let head = max(width * 2.2, square * 0.32)
                let tip = CGPoint(x: end.x - ux * square * 0.15, y: end.y - uy * square * 0.15)
                let shaftEnd = CGPoint(x: tip.x - ux * head, y: tip.y - uy * head)
                let begin = CGPoint(x: start.x + ux * square * 0.25, y: start.y + uy * square * 0.25)

                var headPath = Path()
                let px = -uy, py = ux
                headPath.move(to: tip)
                headPath.addLine(to: CGPoint(x: shaftEnd.x + px * head * 0.6, y: shaftEnd.y + py * head * 0.6))
                headPath.addLine(to: CGPoint(x: shaftEnd.x - px * head * 0.6, y: shaftEnd.y - py * head * 0.6))
                headPath.closeSubpath()

                // Drawn opaque in a layer, which is faded as a whole when it is composited, so
                // where the shaft meets the head nothing shows through twice.
                var faded = ctx
                faded.opacity = arrow.opacity
                faded.drawLayer { layer in
                    let color = GraphicsContext.Shading.color(arrow.color(theme))
                    var shaft = Path()
                    shaft.move(to: begin)
                    if arrow.dashed {
                        // Whole dashes spaced evenly from the start to the head, the last one
                        // meeting it, square-ended like the head's base.
                        shaft.addLine(to: shaftEnd)
                        let run = hypot(shaftEnd.x - begin.x, shaftEnd.y - begin.y)
                        let dash = max(width * 1.6, square * 0.14)
                        let count = max(2, ((run + dash * 0.7) / (dash * 1.7)).rounded())
                        let gap = max(0, (run - count * dash) / (count - 1))
                        layer.stroke(shaft, with: color, style: StrokeStyle(lineWidth: width, lineCap: .butt, dash: [dash, gap]))
                    } else {
                        // Into the head, so the two read as one shape.
                        shaft.addLine(to: CGPoint(x: shaftEnd.x + ux * head * 0.5, y: shaftEnd.y + uy * head * 0.5))
                        layer.stroke(shaft, with: color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    }
                    layer.fill(headPath, with: color)
                }
            }
        }
    }
}
