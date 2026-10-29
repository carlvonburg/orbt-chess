package org.orbtchess.orbt.ui.builder

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.AltRoute
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.automirrored.outlined.Undo
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.AddCircleOutline
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.GpsFixed
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material.icons.outlined.VerticalAlignTop
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.storage.ROOT_NODE
import org.orbtchess.orbt.ui.components.tabularDigits

/**
 * The moves to here, then the main line ahead (what → plays), dimmed; tap a move to go there.
 * Draft moves are dashed (`MovePathStrip`). Scrolls sideways and keeps the current move in view.
 */
@Composable
internal fun MovePathStrip(model: BuilderModel, modifier: Modifier = Modifier) {
    val tree = model.tree
    val current = model.current
    val draft = model.draft
    val path = tree.path(current).drop(1)
    // One list for the moves to here and the line ahead, so going back or forward only moves
    // the highlight: no chip comes or goes.
    val line = path + model.lineAhead
    val hasStart = current != ROOT_NODE || draft.isNotEmpty()
    val first = if (hasStart) 1 else 0
    val target = first + if (draft.isNotEmpty()) line.size + draft.size - 1 else path.size - 1
    val state = rememberLazyListState()
    LaunchedEffect(target) {
        // About two moves before the current one, so it sits inside the strip.
        state.animateScrollToItem(maxOf(0, target - 2))
    }
    LazyRow(
        modifier,
        state = state,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
        contentPadding = PaddingValues(horizontal = 8.dp),
    ) {
        // Only needed once you have left the start position.
        if (hasStart) {
            item("start") {
                IconButton(onClick = { model.go(ROOT_NODE) }) { Icon(BuilderSymbols.start, contentDescription = "Start position") }
            }
        }
        line.forEachIndexed { index, id ->
            val node = tree[id] ?: return@forEachIndexed
            val move = node.mv ?: return@forEachIndexed
            item("move$id") {
                MoveChip(
                    node.ply.toInt(), move.san,
                    isCurrent = id == current && draft.isEmpty(),
                    modifier = Modifier.alpha(if (index < path.size) 1f else 0.45f),
                    onClick = { model.go(id) },
                )
            }
        }
        val basePly = model.node?.ply?.toInt() ?: 0
        draft.forEachIndexed { i, move ->
            item("draft$i") { MoveChip(basePly + i + 1, move.san, isCurrent = i == draft.size - 1, dashed = true) }
        }
    }
}

/** One move of a move list: "1. d4", with the current move highlighted (`MoveChip`). */
@Composable
private fun MoveChip(
    ply: Int,
    san: String,
    isCurrent: Boolean,
    modifier: Modifier = Modifier,
    dashed: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    val shape = RoundedCornerShape(8.dp)
    val color = if (isCurrent) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface.copy(alpha = 0f)
    val outline = MaterialTheme.colorScheme.outline
    val dash = if (dashed) {
        Modifier.drawBehind {
            drawRoundRect(
                outline,
                cornerRadius = CornerRadius(8.dp.toPx()),
                style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.dp.toPx()))),
            )
        }
    } else {
        Modifier
    }
    val body: @Composable () -> Unit = {
        Row(Modifier.padding(horizontal = 8.dp, vertical = 6.dp)) {
            val style = tabularDigits(MaterialTheme.typography.bodyMedium)
            if (ply % 2 == 1) {
                Text("${ply / 2 + 1}.", style = style, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(" ", style = style)
            }
            Text(san, style = style, fontWeight = if (isCurrent) FontWeight.Bold else FontWeight.Normal)
        }
    }
    if (onClick != null) {
        Surface(onClick = onClick, modifier = modifier.then(dash), shape = shape, color = color, content = body)
    } else {
        Surface(modifier = modifier.then(dash), shape = shape, color = color, content = body)
    }
}

/** The Material Symbols Build uses that no other screen does (SF Symbols in the Swift app). */
internal object BuilderSymbols {
    /** "scope": Biggest Gap. */
    val biggestGap: ImageVector get() = Icons.Outlined.GpsFixed
    /** "arrow.uturn.backward": Undo. */
    val undo: ImageVector get() = Icons.AutoMirrored.Outlined.Undo
    /** "list.bullet.indent": Outline. */
    val outline: ImageVector get() = Icons.Outlined.AccountTree
    /** "exclamationmark.circle": Gaps. */
    val gaps: ImageVector get() = Icons.Outlined.ErrorOutline
    /** "note.text": Edit Note. */
    val note: ImageVector get() = Icons.AutoMirrored.Outlined.Notes
    /** "house": the start position. */
    val start: ImageVector get() = Icons.Outlined.Home
    /** "arrow.triangle.branch": a transposition. */
    val transposition: ImageVector get() = Icons.AutoMirrored.Outlined.AltRoute
    /** "nosign": exclude an opponent move. */
    val exclude: ImageVector get() = Icons.Outlined.Block
    /** "plus.circle": include it again. */
    val include: ImageVector get() = Icons.Outlined.AddCircleOutline
    /** "arrow.up.to.line": Make Main Move. */
    val makeMain: ImageVector get() = Icons.Outlined.VerticalAlignTop
    /** "wifi.slash": offline. */
    val offline: ImageVector get() = Icons.Outlined.WifiOff
    /** "hourglass": Lichess asked to slow down. */
    val rateLimited: ImageVector get() = Icons.Outlined.HourglassEmpty
    /** "checkmark.seal": no gaps. */
    val noGaps: ImageVector get() = Icons.Outlined.Verified
}
