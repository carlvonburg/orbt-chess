package org.orbtchess.orbt.ui.training

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

/** The repertoire studied after this one in Study All, and how to start it. */
class NextRepertoire(val name: String, val start: () -> Unit)

/**
 * Study (`DrillView.swift`): lines played from move 1, your moves graded Again/Good, hints,
 * the due counts, the line history; when the session ends, [StudyFinishedScreen] in place (as
 * in Swift, not a separate destination). Called once per pane it fills ([BoardPane]); both
 * share [model].
 *
 * @param next the next repertoire when studying all of them (Study All), else null.
 * @param navigate [Destination.Analysis] (origin [AnalysisOrigin.Study]), [Destination.Builder]
 *   (Show in Build, with its start node), [Destination.Drill] (Learn More), [Destination.CardInfo].
 * @param onBack null where there is nothing to go back to in this pane.
 */
@Composable
fun DrillScreen(
    app: AppModel,
    model: DrillModel,
    pane: BoardPane,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
    next: NextRepertoire? = null,
) {
    // STUB
    Placeholder("Study ($pane)", onBack, modifier) {
        TextButton(onClick = {
            navigate(Destination.Analysis(model.document.entryId, null, emptyList(), Side.WHITE, AnalysisOrigin.Study))
        }) { Text("Analysis") }
    }
}
