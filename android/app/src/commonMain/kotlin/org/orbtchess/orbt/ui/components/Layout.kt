package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.board.LocalBoardShape

/**
 * How a board screen (Build, Study, Study All, Analysis) is shown, which the shell decides from
 * the window's panes (Material's list-detail layout, as on iPad: what you pick from beside the
 * board that shows the pick):
 * - [Whole]: the whole screen, panel and board together, under the screen's top app bar and
 *   scrolling under its floating toolbar ([FloatingToolbarScaffold]; a phone, a tablet in
 *   portrait: one pane).
 * - [List]: the list pane, on the left: the screen's top app bar (back, title, the panel's
 *   actions, menu) over the panel (replies, explorer, counts).
 * - [Detail]: the detail pane, the rest of the window: the board as large as it fits, and under
 *   it the floating toolbar ([BoardToolbar]) as wide as the board, with the move list in it (as
 *   iPad's bar under the board); no top app bar.
 *
 * A screen is called once per pane it fills, with the same model, so both panes show the same
 * state without telling each other.
 */
enum class BoardPane { Whole, List, Detail }

/**
 * The detail pane of a board screen: [BoardColumn] in the space the window leaves, the screen's
 * floating toolbar under the board and as wide as it, laid out under it (never over the board).
 */
@Composable
fun BoardDetailPane(
    modifier: Modifier = Modifier,
    toolbar: @Composable () -> Unit = {},
    above: @Composable ColumnScope.() -> Unit = {},
    board: @Composable () -> Unit,
) {
    Scaffold(modifier) { padding ->
        BoardColumn(
            Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp).padding(top = 16.dp),
            inset = true,
            above = above,
            below = {
                // Material's 16 dp around the floating toolbar, at the toolbar's height (with its
                // FAB, without one, or with none while a study session is finished), so the board
                // keeps its size.
                Box(
                    Modifier.fillMaxWidth().padding(vertical = 16.dp).height(BoardToolbarHeight),
                    contentAlignment = Alignment.Center,
                ) { toolbar() }
            },
            board = board,
        )
    }
}

/**
 * The board column (`BoardColumnLayout` in Swift): what belongs above the board, the board as
 * large as the column allows (square: the full width, or the height left by what is above and
 * under it), then what belongs under it; all three as wide as the board, centred in the column.
 * The board's squares get Material's rounded corners ([LocalBoardShape]) where it sits inset:
 * in a pane with margins ([inset]), or narrower than the column; edge to edge they stay square.
 */
@Composable
fun BoardColumn(
    modifier: Modifier = Modifier,
    inset: Boolean = false,
    above: @Composable ColumnScope.() -> Unit = {},
    below: @Composable ColumnScope.() -> Unit = {},
    board: @Composable () -> Unit,
) {
    val rounded = MaterialTheme.shapes.medium
    // One layout pass: what is above and under the board is asked its height (never squeezed by
    // the board), and the board takes the height they leave, so it has its size from the first
    // frame (a size measured after the first frame made the board jump as the screen came in).
    SubcomposeLayout(modifier) { constraints ->
        val width = constraints.maxWidth
        val aboveSlot = subcompose(BoardColumnSlot.Above) { Column(Modifier.fillMaxWidth(), content = above) }
        val belowSlot = subcompose(BoardColumnSlot.Below) { Column(Modifier.fillMaxWidth(), content = below) }
        fun around(w: Int) = aboveSlot.sumOf { it.maxIntrinsicHeight(w) } + belowSlot.sumOf { it.maxIntrinsicHeight(w) }
        fun sideFor(aroundHeight: Int) =
            if (constraints.hasBoundedHeight) minOf(width, constraints.maxHeight - aroundHeight).coerceAtLeast(0) else width
        // At the column's width, then again at the board's (text above it may wrap more).
        var side = sideFor(around(width))
        if (side < width) side = sideFor(around(side))
        val shape = if (inset || side < width) rounded else RectangleShape
        val boardSlot = subcompose(BoardColumnSlot.Board) {
            Box { CompositionLocalProvider(LocalBoardShape provides shape) { board() } }
        }
        val alongside = Constraints(minWidth = side, maxWidth = side)
        val abovePlaced = aboveSlot.map { it.measure(alongside) }
        val belowPlaced = belowSlot.map { it.measure(alongside) }
        val boardPlaced = boardSlot.map { it.measure(Constraints.fixed(side, side)) }
        val total = abovePlaced.sumOf { it.height } + side + belowPlaced.sumOf { it.height }
        val height = if (constraints.hasBoundedHeight) constraints.maxHeight else total
        layout(width, height) {
            // Centred in the column, as wide as the board.
            val x = (width - side) / 2
            var y = (height - total) / 2
            for (placeable in abovePlaced + boardPlaced + belowPlaced) {
                placeable.place(x, y)
                y += placeable.height
            }
        }
    }
}

private enum class BoardColumnSlot { Above, Board, Below }

/**
 * Nothing to show, and why (SwiftUI's `ContentUnavailableView`): a symbol, a title and a line
 * of explanation, centred in the space it has. Material has no such component.
 */
@Composable
fun EmptyState(
    title: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    description: String? = null,
    actions: @Composable ColumnScope.() -> Unit = {},
) {
    Box(modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Column(
            Modifier.widthIn(max = 420.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(title, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
            if (description != null) {
                Text(
                    description,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }
            actions()
        }
    }
}

/**
 * Shows [content] once the repertoire's document is open, opening it in the background
 * (`OpenDocument` in Swift); a progress indicator meanwhile, the reason when it can't be opened.
 */
@Composable
fun OpenDocument(app: AppModel, entryId: String, content: @Composable (RepertoireDocument) -> Unit) {
    val id = app.documents.currentId(entryId)
    val document = app.documents.documents[id]
    val error = app.documents.openErrors[id]
    when {
        document != null -> content(document)
        error != null -> EmptyState("Repertoire unavailable", Symbols.warning, description = error)
        else -> {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { LoadingIndicator() }
            LaunchedEffect(id) { app.library.entry(id)?.let { app.documents.open(it) } }
        }
    }
}
