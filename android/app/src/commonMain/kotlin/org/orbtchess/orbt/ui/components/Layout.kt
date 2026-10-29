package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireDocument

/**
 * How a board screen (Build, Study, Study All, Analysis) is shown, which the shell decides from
 * the window (`inSplitView` and the board column in the Swift app):
 * - [Whole]: the whole screen, panel and board together (a phone, or a pane alone).
 * - [Panel]: only what is beside the board (moves, explorer, actions), in the list-detail
 *   scaffold's detail pane; the board is in the extra pane.
 * - [Board]: only the board and what belongs right with it (history, navigation), in the extra pane.
 *
 * A screen is called once per pane it fills, with the same model, so both panes show the same
 * state without telling each other.
 */
enum class BoardPane { Whole, Panel, Board }

/**
 * The board column (`BoardColumnLayout` in Swift): what belongs above the board, the board as
 * large as the column allows (square, the full width, or the height in a wide pane, centred in
 * the space left beside it), then what belongs under it.
 */
@Composable
fun BoardColumn(
    modifier: Modifier = Modifier,
    above: @Composable ColumnScope.() -> Unit = {},
    below: @Composable ColumnScope.() -> Unit = {},
    board: @Composable () -> Unit,
) {
    Column(modifier) {
        above()
        BoxWithConstraints(Modifier.weight(1f, fill = false).fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
            val side = minOf(maxWidth, maxHeight)
            Box(Modifier.size(side).aspectRatio(1f)) { board() }
        }
        below()
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
