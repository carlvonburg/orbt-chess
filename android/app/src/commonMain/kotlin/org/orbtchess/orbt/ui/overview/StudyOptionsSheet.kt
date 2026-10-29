package org.orbtchess.orbt.ui.overview

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireDocument

/**
 * A repertoire's study options (`StudyOptionsSheet` in LibraryView.swift, Anki's deck options):
 * daily limits, practice mode. The content of a Material bottom sheet the shell shows.
 *
 * @param onDone closes the sheet.
 */
@Composable
fun StudyOptionsSheet(
    app: AppModel,
    document: RepertoireDocument,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // STUB
    Text("Study Options (not ported yet)", modifier.padding(24.dp))
}
