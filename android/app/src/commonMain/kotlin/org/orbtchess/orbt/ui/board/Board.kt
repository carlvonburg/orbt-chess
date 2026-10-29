package org.orbtchess.orbt.ui.board

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import org.orbtchess.orbt.core.Arrow
import org.orbtchess.orbt.core.ArrowStyle
import org.orbtchess.orbt.core.BoardSquare
import org.orbtchess.orbt.core.PieceKind
import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.Position
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.ui.theme.OrbtTheme

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

/** A badge on a destination square: Study's check or cross (`BoardBadge`). */
data class BoardBadge(val square: BoardSquare, val kind: Kind) {
    enum class Kind { Correct, Wrong }
}

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
    // STUB
    Box(modifier.aspectRatio(1f).background(OrbtTheme.board.light), contentAlignment = Alignment.Center) {
        Text("Board (not ported yet)", color = OrbtTheme.board.ink)
    }
}
