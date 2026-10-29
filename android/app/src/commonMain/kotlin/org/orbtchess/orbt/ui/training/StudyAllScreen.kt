package org.orbtchess.orbt.ui.training

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.Placeholder
import org.orbtchess.orbt.ui.components.BoardPane

/**
 * Study All (`StudyAllView.swift`): [DrillScreen] for each repertoire with moves due today, one
 * after another (its `next`). Called once per pane it fills ([BoardPane]); both share [model].
 *
 * @param navigate as [DrillScreen]'s.
 * @param onBack null where there is nothing to go back to in this pane.
 */
@Composable
fun StudyAllScreen(
    app: AppModel,
    model: StudyAllModel,
    pane: BoardPane,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    // STUB
    Placeholder("Study All ($pane)", onBack, modifier)
}
