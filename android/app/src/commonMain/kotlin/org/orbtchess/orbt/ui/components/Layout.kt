package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireDocument

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
 */
@Composable
fun BoardColumn(
    modifier: Modifier = Modifier,
    above: @Composable ColumnScope.() -> Unit = {},
    below: @Composable ColumnScope.() -> Unit = {},
    board: @Composable () -> Unit,
) {
    BoxWithConstraints(modifier, contentAlignment = Alignment.Center) {
        val density = LocalDensity.current
        // What is above and under the board, measured at their own height (never squeezed by
        // the board): the board takes the height they leave.
        var aboveHeight by remember { mutableStateOf(0.dp) }
        var belowHeight by remember { mutableStateOf(0.dp) }
        val side = minOf(maxWidth, maxHeight - aboveHeight - belowHeight).coerceAtLeast(0.dp)
        Column(Modifier.width(side).wrapContentHeight(unbounded = true)) {
            Column(Modifier.fillMaxWidth().onSizeChanged { aboveHeight = with(density) { it.height.toDp() } }, content = above)
            Box(Modifier.size(side)) { board() }
            Column(Modifier.fillMaxWidth().onSizeChanged { belowHeight = with(density) { it.height.toDp() } }, content = below)
        }
    }
}

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
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            LaunchedEffect(id) { app.library.entry(id)?.let { app.documents.open(it) } }
        }
    }
}
