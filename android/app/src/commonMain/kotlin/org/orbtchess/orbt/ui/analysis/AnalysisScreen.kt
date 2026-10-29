package org.orbtchess.orbt.ui.analysis

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.Placeholder
import org.orbtchess.orbt.ui.components.BoardPane

/**
 * The analysis board (`AnalysisView.swift`): a free tree from the position it was opened on,
 * the engine's lines (Lichess cloud eval, then Stockfish), move navigation, Analyse on Lichess.
 * Going back (the shell calls [AnalysisModel.finish]) hands the line to Build or drops it.
 * Called once per pane it fills ([BoardPane]); both share [model].
 *
 * @param navigate [Destination.Builder] and others, if the screen needs them.
 * @param onBack null where there is nothing to go back to in this pane.
 */
@Composable
fun AnalysisScreen(
    app: AppModel,
    model: AnalysisModel,
    pane: BoardPane,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    // STUB
    Placeholder("Analysis ($pane)", onBack, modifier)
}
