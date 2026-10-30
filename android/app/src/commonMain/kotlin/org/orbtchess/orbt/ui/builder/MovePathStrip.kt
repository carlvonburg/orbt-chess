package org.orbtchess.orbt.ui.builder

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.AltRoute
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.automirrored.outlined.Undo
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.AddCircleOutline
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.GpsFixed
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material.icons.outlined.VerticalAlignTop
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import org.orbtchess.orbt.storage.ROOT_NODE
import org.orbtchess.orbt.ui.components.MoveList
import org.orbtchess.orbt.ui.components.MoveListItem
import org.orbtchess.orbt.ui.components.TooltipIconButton

/**
 * The moves to here, then the main line ahead (what → plays), faint; tap a move to go there.
 * Draft moves are in italics. One list for the moves to here and the line ahead, so going back
 * or forward only moves the highlight.
 */
@Composable
internal fun MovePathStrip(model: BuilderModel, modifier: Modifier = Modifier) {
    val tree = model.tree
    val current = model.current
    val draft = model.draft
    val path = tree.path(current).drop(1)
    val items = buildList {
        (path + model.lineAhead).forEachIndexed { index, id ->
            val node = tree[id] ?: return@forEachIndexed
            val move = node.mv ?: return@forEachIndexed
            val kind = if (index < path.size) MoveListItem.Kind.Played else MoveListItem.Kind.Ahead
            add(MoveListItem(id.toLong(), node.ply.toInt(), move.san, kind, isCurrent = id == current && draft.isEmpty()))
        }
        val basePly = model.node?.ply?.toInt() ?: 0
        draft.forEachIndexed { i, move ->
            add(MoveListItem("draft$i", basePly + i + 1, move.san, MoveListItem.Kind.Draft, isCurrent = i == draft.size - 1))
        }
    }
    MoveList(
        items,
        modifier,
        // Only needed once you have left the start position.
        start = if (current != ROOT_NODE || draft.isNotEmpty()) {
            { TooltipIconButton("Start Position", BuilderSymbols.start, { model.go(ROOT_NODE) }, above = true) }
        } else {
            null
        },
        onMove = { item -> (item.key as? Long)?.let { model.go(it.toUInt()) } },
    )
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
