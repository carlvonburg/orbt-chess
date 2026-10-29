package org.orbtchess.orbt.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ListItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import kotlinx.coroutines.launch
import orbt.app.generated.resources.Res
import org.jetbrains.compose.resources.ExperimentalResourceApi
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.Placeholder
import org.orbtchess.orbt.ui.SetupMode

/**
 * The repertoires (`LibraryView.swift`, its list): by side, each with its coverage and due
 * moves; Settings, New Repertoire and Import in the top app bar; the empty library's welcome
 * (`EmptyLibraryView.swift`). The list pane on wide windows; the Repertoires tab on a phone,
 * where Today (Study All, each repertoire's due moves) is its first section.
 *
 * @param selectedEntryId the repertoire shown beside the list on wide windows (its row is selected), else null.
 * @param showToday true on a phone: Today is the list's first section (on wide windows it is [TodayPane]).
 * @param navigate shows a destination: [Destination.Overview] for a row, [Destination.Settings],
 *   [Destination.Setup], [Destination.StudyAll].
 */
@OptIn(ExperimentalResourceApi::class)
@Composable
fun LibraryScreen(
    app: AppModel,
    selectedEntryId: String?,
    showToday: Boolean,
    navigate: (Destination) -> Unit,
    modifier: Modifier = Modifier,
) {
    // STUB
    val scope = rememberCoroutineScope()
    Placeholder("Repertoires", onBack = null, modifier = modifier) {
        TextButton(onClick = { navigate(Destination.Settings) }) { Text("Settings") }
        TextButton(onClick = { navigate(Destination.Setup(SetupMode.New())) }) { Text("New Repertoire") }
        if (app.library.isLoaded && app.library.entries.isEmpty()) {
            Button(onClick = {
                scope.launch {
                    val bytes = Res.readBytes("files/sample.pgn")
                    app.library.addSample { bytes }
                }
            }) { Text("Add the sample repertoire") }
        }
        LazyColumn {
            items(app.library.entries, key = { it.id }) { entry ->
                ListItem(
                    headlineContent = { Text(entry.name) },
                    supportingContent = { Text(if (entry.needsSetup) "Not set up" else if (entry.id == selectedEntryId) "Selected" else "") },
                    modifier = Modifier.clickable { navigate(Destination.Overview(entry.id)) },
                )
            }
        }
    }
}
