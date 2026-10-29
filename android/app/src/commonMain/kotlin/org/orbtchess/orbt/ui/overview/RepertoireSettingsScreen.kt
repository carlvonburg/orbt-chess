package org.orbtchess.orbt.ui.overview

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.Placeholder

/**
 * A repertoire's settings (`RepertoireSettingsSheet` in LibraryView.swift and
 * `RepertoireSettingsForm.swift`): name, side, coverage database (tables download), coverage
 * target, export, delete. Full window.
 *
 * @param onDeleted the repertoire was deleted: the shell goes back to the library.
 */
@Composable
fun RepertoireSettingsScreen(
    app: AppModel,
    document: RepertoireDocument,
    onBack: () -> Unit,
    onDeleted: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // STUB
    Placeholder("Repertoire Settings", onBack, modifier)
}
