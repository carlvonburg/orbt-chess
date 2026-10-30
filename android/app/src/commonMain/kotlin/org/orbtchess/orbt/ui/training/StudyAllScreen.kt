package org.orbtchess.orbt.ui.training

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.components.BoardPane
import org.orbtchess.orbt.ui.components.EmptyState
import org.orbtchess.orbt.ui.components.Symbols

/**
 * Study All (`StudyAllView.swift`): [DrillScreen] for each repertoire with moves due today, one
 * after another in the library's order (Anki's deck order); its finished screen offers the next
 * one. Called once per pane it fills ([BoardPane]); both share [model].
 *
 * @param navigate as [DrillScreen]'s.
 * @param onBack null where there is nothing to go back to in this pane.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StudyAllScreen(
    app: AppModel,
    model: StudyAllModel,
    pane: BoardPane,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val drill = model.drill
    if (drill != null) {
        val next = model.next?.let { NextRepertoire(it.name) { model.startNext() } }
        // A new screen for each repertoire, as Swift's `.id(index)`.
        key(model.index) {
            DrillScreen(app, drill, pane, navigate, onBack, modifier, next)
        }
        return
    }
    // Opening the next repertoire: in the pane with the top app bar (the list pane on wide windows).
    if (pane == BoardPane.Detail) return
    Scaffold(
        modifier,
        topBar = {
            TopAppBar(
                title = { Text("Study") },
                navigationIcon = {
                    if (onBack != null) {
                        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                    }
                },
            )
        },
    ) { padding ->
        val entry = model.entries.getOrNull(model.index)
        if (entry != null && app.documents.openErrors[entry.id] == null) {
            Column(
                Modifier.padding(padding).fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
            ) {
                CircularProgressIndicator()
                Text("Opening ${entry.name}…")
            }
        } else {
            EmptyState(
                "Repertoire unavailable",
                Symbols.warning,
                Modifier.padding(padding),
                description = entry?.let { app.documents.openErrors[it.id] },
            )
        }
    }
}
