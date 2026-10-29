package org.orbtchess.orbt.ui.library

import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.Placeholder

/**
 * Today across every repertoire (`TodayCard` and the Today column in LibraryView.swift): what is
 * left to do today, Study All, each repertoire's due moves. The detail pane on wide windows
 * while no repertoire is selected (on a phone Today is the library's first section).
 *
 * @param statisticsInline true when no pane beside shows the statistics (a two-pane window):
 *   show every repertoire's statistics under Today.
 * @param navigate [Destination.StudyAll], [Destination.Drill], [Destination.Overview].
 */
@Composable
fun TodayPane(
    app: AppModel,
    statisticsInline: Boolean,
    navigate: (Destination) -> Unit,
    modifier: Modifier = Modifier,
) {
    // STUB
    Placeholder("Today", onBack = null, modifier = modifier) {
        TextButton(onClick = {
            navigate(Destination.StudyAll(app.library.entries.filter { !it.needsSetup }.map { it.id }))
        }) { Text("Study All") }
        if (statisticsInline) Text("Statistics of every repertoire go here")
    }
}
