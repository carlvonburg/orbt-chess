package org.orbtchess.orbt.ui.analysis

import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.builder.BuilderModel

/**
 * The analysis board's state (`AnalysisModel.swift`): the core's `AnalysisSession` (a tree
 * never saved) and the engine. Made by the shell from a
 * [org.orbtchess.orbt.ui.Destination.Analysis].
 *
 * STUB: the constructor and [finish] are the shell's contract; the Analysis screen fills in the rest.
 */
class AnalysisModel(
    val document: RepertoireDocument,
    val startFen: String?,
    val moves: List<PlayedMove>,
    val orientation: Side,
    val origin: Origin,
) {
    /** Where the board was opened from. */
    sealed interface Origin {
        /** Build: [finish] hands the line to this builder as its draft (`Builder::set_line`). */
        class Build(val builder: BuilderModel) : Origin

        /** Study: [finish] drops the line. */
        data object Study : Origin
    }

    /**
     * Called by the shell when the board is popped (not when something covers it): Build gets
     * the path to the selected move as its draft; Study drops it.
     */
    fun finish() {}

    /** Called by the shell after [finish]: stop the engine, free the core session. */
    fun close() {}
}
