package org.orbtchess.orbt.ui.library

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireEntry
import org.orbtchess.orbt.ui.Placeholder
import org.orbtchess.orbt.ui.SetupMode

/**
 * The step-by-step setup of a new, imported or dropped-in repertoire (`RepertoireSetupFlow.swift`):
 * name and side, opponents (coverage database), depth (coverage target). Full window.
 *
 * @param onDone the repertoire made or set up: the shell shows its overview (a new one opens on Build).
 * @param onCancel leaves without adding anything.
 */
@Composable
fun SetupScreen(
    app: AppModel,
    mode: SetupMode,
    onDone: (RepertoireEntry) -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // STUB
    Placeholder("New Repertoire", onBack = onCancel, modifier = modifier)
}
