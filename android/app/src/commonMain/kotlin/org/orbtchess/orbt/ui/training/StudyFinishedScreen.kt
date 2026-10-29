package org.orbtchess.orbt.ui.training

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.Destination

/**
 * The end of a study session (`StudyFinishedView.swift`): what was studied, the progress,
 * what comes next (later today, Learn More, the next repertoire in Study All). Shown by
 * [DrillScreen] in place of the board when the session ends, not navigated to.
 *
 * @param next the next repertoire when studying all of them.
 * @param navigate [Destination.Drill] (Learn More), [Destination.Overview].
 * @param onDone back to where Study was opened from.
 */
@Composable
fun StudyFinishedScreen(
    app: AppModel,
    model: DrillModel,
    next: NextRepertoire?,
    navigate: (Destination) -> Unit,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // STUB
    Text("Study finished (not ported yet)", modifier)
}
