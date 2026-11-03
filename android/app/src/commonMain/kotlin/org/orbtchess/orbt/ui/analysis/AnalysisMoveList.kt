package org.orbtchess.orbt.ui.analysis

import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import org.orbtchess.orbt.ui.components.ExpressiveMenu
import org.orbtchess.orbt.ui.components.onSecondaryClick
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.core.AnalysisMove
import org.orbtchess.orbt.core.MoveListRow
import org.orbtchess.orbt.core.MoveToken
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.components.tabularDigits

/**
 * The moves of the analysis, laid out by the core as lichess's app does ([MoveListRow]): the
 * main line one full move per row, each variation a row under the move it replaces, with a guide
 * per level. Tap a move to go to it; long-press it to promote, copy or delete its line.
 * Items of a lazy list, one per row (so the list can scroll to [AnalysisModel.State.currentRow]).
 */
internal fun LazyListScope.analysisMoveList(model: AnalysisModel, rows: List<MoveListRow>) {
    if (rows.isEmpty()) {
        item {
            Text(
                "Play a move on the board.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
        }
    }
    rows.forEachIndexed { index, row ->
        item {
            when (row) {
                is MoveListRow.Main -> Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "${row.v1.number}",
                        style = tabularDigits(),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.widthIn(min = 28.dp),
                    )
                    MainCell(model, row.v1.white)
                    // "…" where the line goes on below the variations, nothing at its end;
                    // it keeps its half either way, so White's move stays its width.
                    if (row.v1.black != null || index < rows.size - 1) {
                        MainCell(model, row.v1.black)
                    } else {
                        Spacer(Modifier.weight(1f))
                    }
                }
                is MoveListRow.Variation -> VariationRow(model, row.v1.guides, row.v1.tokens)
            }
        }
    }
}

@Composable
private fun RowScope.MainCell(model: AnalysisModel, move: AnalysisMove?) {
    if (move == null) {
        Text(
            "…",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f).padding(horizontal = 6.dp),
        )
        return
    }
    MoveButton(model, move, Modifier.weight(1f)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(move.san, fontWeight = if (move.isCurrent) FontWeight.SemiBold else FontWeight.Normal, modifier = Modifier.weight(1f))
            move.eval?.let {
                Text(it, style = tabularDigits(MaterialTheme.typography.labelSmall), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun VariationRow(model: AnalysisModel, guides: List<Boolean>, tokens: List<MoveToken>) {
    val guide = MaterialTheme.colorScheme.outlineVariant
    Row(
        Modifier.fillMaxWidth().height(IntrinsicSize.Min)
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        guides.forEachIndexed { level, goesOn ->
            // One level of the guides: an outer level's line passing by (if it goes on), or this
            // row's own ├ or └.
            val own = level == guides.size - 1
            Box(
                Modifier.width(12.dp).fillMaxHeight().drawBehind {
                    val x = 0.5f
                    val tick = 16.dp.toPx()
                    val stroke = 1.dp.toPx()
                    if (own) {
                        drawLine(guide, Offset(x, 0f), Offset(x, if (goesOn) size.height else tick), stroke)
                        drawLine(guide, Offset(x, tick), Offset(size.width, tick), stroke)
                    } else if (goesOn) {
                        drawLine(guide, Offset(x, 0f), Offset(x, size.height), stroke)
                    }
                },
            )
        }
        FlowRow(
            Modifier.weight(1f).padding(vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
            itemVerticalAlignment = Alignment.CenterVertically,
        ) {
            tokens.forEach { token ->
                when (token) {
                    is MoveToken.Move -> MoveButton(model, token.v1) { VariationMove(token.v1) }
                    MoveToken.Open -> Text("(", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    MoveToken.Close -> Text(")", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

/** One move of a variation: number, move and the evaluation after it. */
@Composable
private fun VariationMove(move: AnalysisMove) {
    val style = tabularDigits(MaterialTheme.typography.bodyMedium)
    Row(
        Modifier.padding(horizontal = 6.dp, vertical = 3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        move.number?.let { Text(it, style = style, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Text(move.san, style = style, fontWeight = if (move.isCurrent) FontWeight.SemiBold else FontWeight.Normal)
        move.eval?.let {
            Text(it, style = tabularDigits(MaterialTheme.typography.labelSmall), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** A move: tap to go to it, long-press (or right-click) for its menu; the current one highlighted. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MoveButton(model: AnalysisModel, move: AnalysisMove, modifier: Modifier = Modifier, label: @Composable () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    var menuAt by remember { mutableStateOf<IntOffset?>(null) }
    val shape = RoundedCornerShape(6.dp)
    Box(modifier) {
        Box(
            Modifier.clip(shape)
                .then(if (move.isCurrent) Modifier.background(MaterialTheme.colorScheme.secondaryContainer) else Modifier)
                .onSecondaryClick { menuAt = it; menu = true }
                .combinedClickable(onLongClick = { menuAt = null; menu = true }) { model.go(move.id) },
        ) { label() }
        MoveMenu(model, move, menu, menuAt) { menu = false }
    }
}

@Suppress("DEPRECATION")
@Composable
private fun MoveMenu(model: AnalysisModel, move: AnalysisMove, expanded: Boolean, at: IntOffset?, dismiss: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    val variation = expanded && !model.isMainLine(move.id)
    ExpressiveMenu(expanded, onDismissRequest = dismiss, at = at) {
        if (variation) {
            group {
                item("Promote Variation", Icons.Filled.KeyboardArrowUp) { model.promote(move.id) }
                item("Make Main Line", Icons.Filled.Check) { model.makeMainLine(move.id) }
            }
        }
        group {
            item("Copy Variation PGN", Icons.Outlined.ContentCopy) { clipboard.setText(AnnotatedString(model.linePgn(move.id))) }
            item("Delete from Here", Symbols.delete, destructive = true) { model.deleteFrom(move.id) }
        }
    }
}
