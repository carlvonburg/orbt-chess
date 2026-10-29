package org.orbtchess.orbt.ui.builder

import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.ui.AnalysisOrigin
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.Placeholder
import org.orbtchess.orbt.ui.components.BoardPane

/**
 * Build (`BuilderView.swift`, `BuilderSheets.swift`): the board with your moves, replies and
 * gaps, the explorer, the move history and navigation, adding and deleting moves, the gap list,
 * notes. Called once per pane it fills ([BoardPane]); both share [model].
 *
 * @param navigate [Destination.Analysis] (origin [AnalysisOrigin.Build]), [Destination.Drill]
 *   (Study Branch), [Destination.CardInfo].
 * @param onBack null where there is nothing to go back to in this pane (the board pane beside the panel).
 */
@Composable
fun BuilderScreen(
    app: AppModel,
    model: BuilderModel,
    pane: BoardPane,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    // STUB
    Placeholder("Build ($pane)", onBack, modifier) {
        TextButton(onClick = {
            navigate(Destination.Analysis(model.document.entryId, null, emptyList(), Side.WHITE, AnalysisOrigin.Build))
        }) { Text("Analysis") }
    }
}
