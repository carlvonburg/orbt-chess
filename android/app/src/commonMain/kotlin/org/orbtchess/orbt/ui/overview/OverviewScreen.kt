package org.orbtchess.orbt.ui.overview

import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.DrillKind
import org.orbtchess.orbt.ui.Placeholder

/**
 * A repertoire's overview (`RepertoireOverviewView.swift`, Anki's deck overview): coverage
 * (gaps, Edit Lines), study (due counts, Study, Learn More, Practice), its settings and study
 * options. Runs the background coverage check while shown. The detail pane on wide windows;
 * pushed on the library on a phone.
 *
 * @param statisticsInline true on a two-pane window, where no pane beside shows this
 *   repertoire's statistics: show them under the overview.
 * @param navigate [Destination.Builder], [Destination.Drill], [Destination.RepertoireSettings],
 *   [Destination.StudyOptions], [Destination.Overview] (switching repertoire).
 * @param onBack null where the overview is beside the library (nothing to go back to).
 */
@Composable
fun OverviewScreen(
    app: AppModel,
    document: RepertoireDocument,
    statisticsInline: Boolean,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    // STUB
    val id = document.entryId
    Placeholder(document.name, onBack, modifier) {
        TextButton(onClick = { navigate(Destination.Builder(id)) }) { Text("Edit Lines") }
        TextButton(onClick = { navigate(Destination.Drill(id, DrillKind.Study)) }) { Text("Study") }
        TextButton(onClick = { navigate(Destination.Drill(id, DrillKind.Practice)) }) { Text("Practice") }
        TextButton(onClick = { navigate(Destination.RepertoireSettings(id)) }) { Text("Repertoire Settings") }
        TextButton(onClick = { navigate(Destination.StudyOptions(id)) }) { Text("Study Options") }
        if (statisticsInline) Text("This repertoire's statistics go here")
    }
}
