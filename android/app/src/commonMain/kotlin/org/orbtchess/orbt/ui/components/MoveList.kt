package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * One move of a [MoveList]: its ply (1 is White's first move), what it is to the board, and
 * whether it is the move on the board.
 */
data class MoveListItem(val key: Any, val ply: Int, val san: String, val kind: Kind = Kind.Played, val isCurrent: Boolean = false) {
    enum class Kind {
        /** Played to reach the board (or the move on it). */
        Played,

        /** Ahead of the board on the line (what → plays). */
        Ahead,

        /** Not saved yet (Build's line being entered). */
        Draft,
    }
}

/**
 * The moves of a line under the board, one row that scrolls sideways (as chess apps on Android
 * show them): "1. e4 e5 2. Nf3", the move on the board highlighted and kept in view, the moves
 * ahead faint and unsaved ones in italics. Material has no move list, so this is text on its
 * surface roles. Back and forward are the screen's toolbar buttons, not part of it.
 *
 * @param start the start position before the first move, a button leading the row (null: none).
 * @param onMove going to a move; null when the moves are only shown (a study line).
 */
@Composable
fun MoveList(
    moves: List<MoveListItem>,
    modifier: Modifier = Modifier,
    start: (@Composable () -> Unit)? = null,
    onMove: ((MoveListItem) -> Unit)? = null,
) {
    val state = rememberLazyListState()
    val current = moves.indexOfFirst { it.isCurrent }
    val offset = if (start != null) 1 else 0
    LaunchedEffect(current) {
        // A move or two before the current one, so it sits inside the row.
        if (current >= 0) state.animateScrollToItem(maxOf(0, current + offset - 2))
    }
    LazyRow(
        modifier.fillMaxWidth().heightIn(min = 48.dp).fadingEdges(state),
        state = state,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically,
        contentPadding = PaddingValues(horizontal = 8.dp),
    ) {
        if (start != null) item("start") { start() }
        itemsIndexed(moves, key = { _, move -> move.key }) { index, move ->
            MoveText(move, numbered = index == 0, onClick = onMove?.let { { it(move) } })
        }
    }
}

@Composable
private fun MoveText(move: MoveListItem, numbered: Boolean, onClick: (() -> Unit)?) {
    val colors = MaterialTheme.colorScheme
    val isCurrent = move.isCurrent
    val textColor = when {
        isCurrent -> colors.onSecondaryContainer
        move.kind == MoveListItem.Kind.Ahead -> colors.onSurfaceVariant.copy(alpha = 0.6f)
        else -> colors.onSurface
    }
    val style = tabularDigits(MaterialTheme.typography.bodyLarge)
    val number = when {
        move.ply % 2 == 1 -> "${move.ply / 2 + 1}."
        numbered -> "${move.ply / 2}…"
        else -> null
    }
    val content: @Composable () -> Unit = {
        Row(Modifier.padding(horizontal = 6.dp, vertical = 4.dp)) {
            if (number != null) Text("$number ", style = style, color = colors.onSurfaceVariant)
            Text(
                move.san,
                style = style,
                color = textColor,
                fontWeight = if (isCurrent) FontWeight.SemiBold else null,
                fontStyle = if (move.kind == MoveListItem.Kind.Draft) FontStyle.Italic else null,
            )
        }
    }
    val shape = MaterialTheme.shapes.small
    val container = if (isCurrent) colors.secondaryContainer else Color.Transparent
    val described = Modifier.semantics {
        val states = listOfNotNull(
            "On the board".takeIf { move.isCurrent },
            "Not saved".takeIf { move.kind == MoveListItem.Kind.Draft },
        )
        if (states.isNotEmpty()) stateDescription = states.joinToString(", ")
    }
    if (onClick != null) {
        Surface(onClick = onClick, modifier = described, shape = shape, color = container, content = content)
    } else {
        Surface(modifier = described, shape = shape, color = container, content = content)
    }
}

/** The fade's mask: only its alpha counts (DstIn keeps the row where the mask is opaque). */
private val Opaque = Color.Transparent.copy(alpha = 1f)

/** How far the row's ends fade where it scrolls on (as iOS's scroll edge). */
private val FadeWidth = 24.dp

/**
 * Fades the row's ends where there are more moves to scroll to (iOS's soft scroll edge), so the
 * row doesn't end in a cut-off move; an end that can't scroll stays sharp.
 */
private fun Modifier.fadingEdges(state: LazyListState): Modifier = this
    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
    .drawWithContent {
        drawContent()
        val fade = FadeWidth.toPx().coerceAtMost(size.width / 2)
        if (state.canScrollBackward) {
            drawRect(
                Brush.horizontalGradient(listOf(Color.Transparent, Opaque), startX = 0f, endX = fade),
                size = Size(fade, size.height),
                blendMode = BlendMode.DstIn,
            )
        }
        if (state.canScrollForward) {
            drawRect(
                Brush.horizontalGradient(listOf(Opaque, Color.Transparent), startX = size.width - fade, endX = size.width),
                topLeft = Offset(size.width - fade, 0f),
                size = Size(fade, size.height),
                blendMode = BlendMode.DstIn,
            )
        }
    }
