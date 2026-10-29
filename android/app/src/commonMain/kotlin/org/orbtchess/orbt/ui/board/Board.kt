package org.orbtchess.orbt.ui.board

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.lerp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import org.jetbrains.compose.resources.painterResource
import org.orbtchess.orbt.core.Arrow
import org.orbtchess.orbt.core.ArrowStyle
import org.orbtchess.orbt.core.BoardSquare
import org.orbtchess.orbt.core.PieceKind
import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.Position
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.boardSquare
import org.orbtchess.orbt.core.file
import org.orbtchess.orbt.core.from
import org.orbtchess.orbt.core.isLight
import org.orbtchess.orbt.core.rank
import org.orbtchess.orbt.core.to
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.theme.BoardTheme
import org.orbtchess.orbt.ui.theme.OrbtTheme
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.roundToInt

/** An arrow on the board (`BoardArrow` in BoardView.swift), drawn in the board's ink (the engine's in graphite). */
data class BoardArrow(
    val from: BoardSquare,
    val to: BoardSquare,
    val style: Style,
    /** Width as a fraction of a square (0.08...0.3). */
    val width: Double = 0.18,
    val opacity: Double = 0.85,
    val dashed: Boolean = false,
) {
    enum class Style { Mine, Opponent, Gap, Hint, Engine }

    fun color(theme: BoardTheme): Color = when (style) {
        Style.Mine, Style.Opponent, Style.Hint, Style.Gap -> theme.ink
        Style.Engine -> theme.engine
    }
}

/** The core's arrow (Build's moves, replies and gaps, Study's hint) as drawn. */
fun Arrow.toBoardArrow(): BoardArrow = BoardArrow(
    from = from,
    to = to,
    style = when (style) {
        ArrowStyle.MINE -> BoardArrow.Style.Mine
        ArrowStyle.OPPONENT -> BoardArrow.Style.Opponent
        ArrowStyle.GAP -> BoardArrow.Style.Gap
        ArrowStyle.HINT -> BoardArrow.Style.Hint
    },
    width = width,
    opacity = opacity,
    dashed = dashed,
)

/** A mark in the top-right corner of a square: how the move to it was judged (Study's check or cross). */
data class BoardBadge(val square: BoardSquare, val kind: Kind) {
    enum class Kind { Correct, Wrong }
}

/** A move made by dragging: the piece stays where it was dropped instead of sliding there. */
private class Drop(val from: BoardSquare, val to: BoardSquare, val side: Side, val fen: String)

/**
 * The interactive chess board (`BoardView.swift`): tap-tap or drag to move, legal-move dots,
 * last-move highlight, promotion picker, arrows, badges and sliding pieces. Square; colors from
 * [OrbtTheme.board]. Custom drawing: Material has no board.
 *
 * @param movableSide which side may be moved; null disables interaction.
 * @param onMove a move made on the board: from, to, and the piece promoted to.
 */
@Composable
fun Board(
    position: Position,
    modifier: Modifier = Modifier,
    orientation: Side = Side.WHITE,
    lastMove: PlayedMove? = null,
    arrows: List<BoardArrow> = emptyList(),
    badge: BoardBadge? = null,
    movableSide: Side? = null,
    onMove: (from: BoardSquare, to: BoardSquare, promotion: PieceKind?) -> Unit = { _, _, _ -> },
) {
    val theme = OrbtTheme.board
    val fen = position.fen()
    var selected by remember { mutableStateOf<BoardSquare?>(null) }
    var dragFrom by remember { mutableStateOf<BoardSquare?>(null) }
    var dragLocation by remember { mutableStateOf<Offset?>(null) }
    var promotion by remember { mutableStateOf<Pair<BoardSquare, BoardSquare>?>(null) }
    var drop by remember { mutableStateOf<Drop?>(null) }

    // The layout follows the position in the same frame; a move dropped by dragging doesn't slide.
    val layout = remember { PieceLayout() }
    var first by remember { mutableStateOf(true) }
    val update = remember(fen) {
        val played = drop?.let { it.fen != fen && position.pieceAt(it.to)?.side == it.side } == true
        layout.update(position, animated = !first && !played)
    }
    val haptic = LocalHapticFeedback.current
    LaunchedEffect(fen) {
        if (!first) haptic.performHapticFeedback(HapticFeedbackType.SegmentTick)
        first = false
        selected = null
        drop = null
    }

    val currentPosition by rememberUpdatedState(position)
    val currentOrientation by rememberUpdatedState(orientation)
    val currentMovableSide by rememberUpdatedState(movableSide)
    val currentOnMove by rememberUpdatedState(onMove)

    BoxWithConstraints(
        modifier.aspectRatio(1f).clearAndSetSemantics { contentDescription = "Chess board" },
        contentAlignment = Alignment.Center,
    ) {
        val density = LocalDensity.current
        val sizePx = with(density) { minOf(maxWidth, maxHeight).toPx() }
        val sq = sizePx / 8
        val sqDp = with(density) { sq.toDp() }
        val geometry = BoardGeometry(sq, orientation)

        fun canMove(from: BoardSquare): Boolean {
            val side = currentMovableSide ?: return false
            val piece = currentPosition.pieceAt(from) ?: return false
            return piece.side == side && piece.side == currentPosition.sideToMove()
        }

        fun attemptMove(from: BoardSquare, to: BoardSquare, dragged: Boolean = false) {
            val position = currentPosition
            if (to !in position.legalDestinations(from)) {
                selected = if (canMove(to)) to else null
                return
            }
            if (position.isPromotion(from, to)) {
                promotion = from to to
                return
            }
            selected = null
            if (dragged) position.pieceAt(from)?.side?.let { drop = Drop(from, to, it, position.fen()) }
            currentOnMove(from, to, null)
        }

        Box(
            Modifier
                .size(sqDp * 8)
                .pointerInput(sq) {
                    val slop = 6.dp.toPx()
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        if (currentMovableSide == null || promotion != null) return@awaitEachGesture
                        val g = BoardGeometry(sq, currentOrientation)
                        val start = g.square(down.position)
                        if (start != null && canMove(start)) dragFrom = start
                        var location = down.position
                        var dragging = false
                        try {
                            while (true) {
                                val event = awaitPointerEvent()
                                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                                location = change.position
                                if (!change.pressed) break
                                if (change.positionChange() != Offset.Zero) change.consume()
                                if (dragFrom != null && (location - down.position).getDistance() > slop) {
                                    dragging = true
                                    dragLocation = location
                                    selected = dragFrom
                                }
                            }
                            val target = g.square(location) ?: return@awaitEachGesture
                            val from = dragFrom
                            if (dragging && from != null) {
                                if (from != target) attemptMove(from, target, dragged = true)
                                return@awaitEachGesture
                            }
                            // Tap
                            val chosen = selected
                            if (chosen != null && chosen != target && target in currentPosition.legalDestinations(chosen)) {
                                attemptMove(chosen, target)
                            } else if (canMove(target) && selected != target) {
                                selected = target
                            } else {
                                selected = null
                            }
                        } finally {
                            dragFrom = null
                            dragLocation = null
                        }
                    }
                },
        ) {
            val legal = remember(fen, selected) { selected?.let { position.legalDestinations(it).toSet() } ?: emptySet() }
            val occupied = remember(fen) { position.pieces().map { it.square }.toSet() }
            Canvas(Modifier.fillMaxSize()) {
                drawSquares(geometry, theme, lastMove, selected, legal, occupied)
            }
            Coordinates(geometry, theme)

            // Pieces: captured ones fade out under the one that takes them, as SwiftUI's default transition.
            if (update.animated) {
                for (piece in update.removed) key("removed", piece.id, update) {
                    PieceImage(piece.side, piece.kind, sqDp, Modifier.placed(geometry.topLeft(piece.square)), fade = Fade.Out)
                }
            }
            for (piece in update.pieces) key(piece.id) {
                val isDragged = piece.square == dragFrom && dragLocation != null
                val from = update.movedFrom[piece.id]?.takeIf { update.animated }
                val slide = remember(update) { if (from != null) Animatable(0f) else null }
                LaunchedEffect(slide) { slide?.animateTo(1f, tween(150, easing = LinearOutSlowInEasing)) }
                val placement = Modifier
                    .zIndex(if (isDragged) 10f else 1f)
                    .graphicsLayer {
                        val at = when {
                            isDragged -> (dragLocation ?: geometry.center(piece.square)) - Offset(sq / 2, sq / 2)
                            from != null && slide != null -> lerp(geometry.topLeft(from), geometry.topLeft(piece.square), slide.value)
                            else -> geometry.topLeft(piece.square)
                        }
                        translationX = at.x
                        translationY = at.y
                    }
                val fade = if (update.animated && piece.id in update.added) Fade.In else null
                PieceImage(piece.side, piece.kind, sqDp, placement, fade = fade, key = update)
            }

            Canvas(Modifier.fillMaxSize().zIndex(5f)) {
                for (arrow in arrows) drawArrow(arrow, geometry, theme)
            }
            BadgeLayer(badge, geometry, theme, Modifier.zIndex(6f))

            promotion?.let { (from, to) ->
                PromotionPicker(
                    side = position.sideToMove(),
                    at = geometry.center(to),
                    sq = sq,
                    theme = theme,
                    onDismiss = { promotion = null },
                    onPick = { kind ->
                        promotion = null
                        selected = null
                        currentOnMove(from, to, kind)
                    },
                    modifier = Modifier.zIndex(20f),
                )
            }
        }
    }
}

// MARK: Geometry

/** Squares to pixels and back for one board size and orientation. */
private class BoardGeometry(val sq: Float, val orientation: Side) {
    fun topLeft(square: BoardSquare): Offset {
        val col = if (orientation == Side.WHITE) square.file else 7 - square.file
        val row = if (orientation == Side.WHITE) 7 - square.rank else square.rank
        return Offset(col * sq, row * sq)
    }

    fun rect(square: BoardSquare): Rect = Rect(topLeft(square), Size(sq, sq))

    fun center(square: BoardSquare): Offset = topLeft(square) + Offset(sq / 2, sq / 2)

    fun square(point: Offset): BoardSquare? {
        if (point.x < 0 || point.y < 0) return null
        val col = (point.x / sq).toInt()
        val row = (point.y / sq).toInt()
        if (col !in 0..7 || row !in 0..7) return null
        val file = if (orientation == Side.WHITE) col else 7 - col
        val rank = if (orientation == Side.WHITE) 7 - row else row
        return boardSquare(file, rank)
    }
}

private fun Modifier.placed(at: Offset): Modifier = offset { IntOffset(at.x.roundToInt(), at.y.roundToInt()) }

// MARK: Drawing

private fun DrawScope.drawSquares(
    g: BoardGeometry,
    theme: BoardTheme,
    lastMove: PlayedMove?,
    selected: BoardSquare?,
    legal: Set<BoardSquare>,
    occupied: Set<BoardSquare>,
) {
    val sq = g.sq
    val lastFrom = lastMove?.from
    val lastTo = lastMove?.to
    for (index in 0 until 64) {
        val square = BoardSquare(index.toUByte())
        val rect = g.rect(square)
        drawRect(if (square.isLight) theme.light else theme.dark, rect.topLeft, rect.size)
        if (square == lastFrom || square == lastTo) drawRect(theme.lastMove, rect.topLeft, rect.size)
        if (square == selected) drawRect(theme.selected, rect.topLeft, rect.size)
        if (square in legal) {
            if (square in occupied) {
                // A ring inset by 0.04 of a square, 0.08 wide.
                drawCircle(theme.captureRing, radius = sq / 2 - sq * 0.04f, center = rect.center, style = Stroke(sq * 0.08f))
            } else {
                drawCircle(theme.moveDot, radius = sq / 2 - sq * 0.36f, center = rect.center)
            }
        }
    }
}

/** File letters along the bottom and rank numbers down the left, in the opposite square's color. */
@Composable
private fun Coordinates(g: BoardGeometry, theme: BoardTheme) {
    val measurer = rememberTextMeasurer()
    val fontSize = with(LocalDensity.current) { (g.sq * 0.2f).toSp() }
    Canvas(Modifier.fillMaxSize()) {
        val sq = g.sq
        val white = g.orientation == Side.WHITE
        fun label(text: String, color: Color, center: Offset) {
            val layout = measurer.measure(text, TextStyle(color = color, fontSize = fontSize, fontWeight = FontWeight.SemiBold))
            drawText(layout, topLeft = center - Offset(layout.size.width / 2f, layout.size.height / 2f))
        }
        for (i in 0 until 8) {
            val file = if (white) i else 7 - i
            val rank = if (white) 7 - i else i
            label(
                ('a' + file).toString(),
                theme.coordinate(boardSquare(file, if (white) 0 else 7).isLight),
                Offset(i * sq + sq * 0.86f, sq * 7.84f),
            )
            label(
                "${rank + 1}",
                theme.coordinate(boardSquare(if (white) 0 else 7, rank).isLight),
                Offset(sq * 0.12f, i * sq + sq * 0.16f),
            )
        }
    }
}

private enum class Fade { In, Out }

@Composable
private fun PieceImage(side: Side, kind: PieceKind, size: Dp, modifier: Modifier, fade: Fade? = null, key: Any? = null) {
    val alpha = remember(key, fade) { fade?.let { Animatable(if (it == Fade.In) 0f else 1f) } }
    LaunchedEffect(alpha) { alpha?.animateTo(if (fade == Fade.In) 1f else 0f, tween(150, easing = LinearOutSlowInEasing)) }
    Image(
        painterResource(pieceDrawable(side, kind)),
        contentDescription = null,
        modifier = modifier.size(size).let { m -> if (alpha != null) m.graphicsLayer { this.alpha = alpha.value } else m },
    )
}

/** An arrow from square centre to square centre, faded as a whole so the shaft and head don't overlap twice. */
private fun DrawScope.drawArrow(arrow: BoardArrow, g: BoardGeometry, theme: BoardTheme) {
    val square = g.sq
    val start = g.center(arrow.from)
    val end = g.center(arrow.to)
    val dx = end.x - start.x
    val dy = end.y - start.y
    val length = hypot(dx, dy)
    if (length <= 0f) return
    val ux = dx / length
    val uy = dy / length
    val width = square * arrow.width.toFloat()
    val head = max(width * 2.2f, square * 0.32f)
    val tip = Offset(end.x - ux * square * 0.15f, end.y - uy * square * 0.15f)
    val shaftEnd = Offset(tip.x - ux * head, tip.y - uy * head)
    val begin = Offset(start.x + ux * square * 0.25f, start.y + uy * square * 0.25f)
    val px = -uy
    val py = ux
    val headPath = Path().apply {
        moveTo(tip.x, tip.y)
        lineTo(shaftEnd.x + px * head * 0.6f, shaftEnd.y + py * head * 0.6f)
        lineTo(shaftEnd.x - px * head * 0.6f, shaftEnd.y - py * head * 0.6f)
        close()
    }
    val color = arrow.color(theme)
    // Drawn opaque in a layer, which is faded as a whole when it is composited, so where the
    // shaft meets the head nothing shows through twice.
    drawIntoCanvas { it.saveLayer(Rect(Offset.Zero, size), Paint().apply { alpha = arrow.opacity.toFloat() }) }
    if (arrow.dashed) {
        // Whole dashes spaced evenly from the start to the head, the last one meeting it,
        // square-ended like the head's base.
        val run = hypot(shaftEnd.x - begin.x, shaftEnd.y - begin.y)
        val dash = max(width * 1.6f, square * 0.14f)
        val count = max(2f, ((run + dash * 0.7f) / (dash * 1.7f)).roundToInt().toFloat())
        val gap = max(0f, (run - count * dash) / (count - 1))
        drawLine(color, begin, shaftEnd, width, StrokeCap.Butt, PathEffect.dashPathEffect(floatArrayOf(dash, gap)))
    } else {
        // Into the head, so the two read as one shape.
        drawLine(color, begin, Offset(shaftEnd.x + ux * head * 0.5f, shaftEnd.y + uy * head * 0.5f), width, StrokeCap.Round)
    }
    drawPath(headPath, color)
    drawIntoCanvas { it.restore() }
}

/** The badge in the top-right corner of its square: a white check or cross on a colored disc. */
@Composable
private fun BadgeLayer(badge: BoardBadge?, g: BoardGeometry, theme: BoardTheme, modifier: Modifier) {
    // Kept while it animates out.
    val shown = remember { object { var badge: BoardBadge? = null } }
    if (badge != null) shown.badge = badge
    val last = shown.badge ?: return
    val density = LocalDensity.current
    val sq = g.sq
    val diameter = sq * 0.38f
    val r = g.rect(last.square)
    val at = Offset(r.right - sq * 0.2f, r.top + sq * 0.2f) - Offset(diameter / 2, diameter / 2)
    val correct = last.kind == BoardBadge.Kind.Correct
    Box(modifier.fillMaxSize()) {
        AnimatedVisibility(
            visible = badge != null,
            modifier = Modifier.placed(at),
            enter = scaleIn(tween(200), initialScale = 0.3f) + fadeIn(tween(200)),
            exit = scaleOut(tween(200), targetScale = 0.3f) + fadeOut(tween(200)),
        ) {
            val size = with(density) { diameter.toDp() }
            Box(
                Modifier
                    .size(size)
                    .shadow(1.5.dp, CircleShape)
                    .background(if (correct) theme.correct else theme.wrong, CircleShape),
            ) {
                Icon(
                    if (correct) Symbols.correct else Symbols.wrong,
                    contentDescription = null,
                    tint = theme.badgeGlyph,
                    modifier = Modifier.fillMaxSize().padding(size * 0.16f),
                )
            }
        }
    }
}

/**
 * The badge's glyph: white on its disc, as SF Symbols' palette rendering in Swift. `BoardTheme`
 * has no role for it yet; the result bar's text on black is that white.
 */
private val BoardTheme.badgeGlyph: Color get() = resultText(blackResult)

/** The four pieces to promote to, in a column from the promotion square into the board, over a scrim. */
@Composable
private fun PromotionPicker(
    side: Side,
    at: Offset,
    sq: Float,
    theme: BoardTheme,
    onDismiss: () -> Unit,
    onPick: (PieceKind) -> Unit,
    modifier: Modifier,
) {
    val kinds = listOf(PieceKind.QUEEN, PieceKind.KNIGHT, PieceKind.ROOK, PieceKind.BISHOP)
    val downward = at.y < sq * 4
    val sqDp = with(LocalDensity.current) { sq.toDp() }
    Box(
        modifier
            .fillMaxSize()
            .background(theme.promotionScrim)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
    ) {
        val top = if (downward) at.y - sq / 2 else at.y - sq * 3.5f
        Surface(
            modifier = Modifier.placed(Offset(at.x - sq / 2, top)),
            shape = MaterialTheme.shapes.small,
            tonalElevation = 3.dp,
            shadowElevation = 3.dp,
        ) {
            Column {
                for (kind in if (downward) kinds else kinds.reversed()) {
                    Image(
                        painterResource(pieceDrawable(side, kind)),
                        contentDescription = kind.title,
                        modifier = Modifier.size(sqDp).clickable { onPick(kind) },
                    )
                }
            }
        }
    }
}
