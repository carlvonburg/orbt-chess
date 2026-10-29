package org.orbtchess.orbt.ui.training

import org.orbtchess.orbt.core.DrillMode
import org.orbtchess.orbt.storage.RepertoireDocument

/**
 * Study's state (`DrillModel` in DrillView.swift): a thin observable wrapper over the core's
 * `DrillSession`, with the step clock. Made by the shell before Study is shown and shared by
 * its panes.
 *
 * STUB: the constructor is the shell's contract; the Study screen fills in the rest.
 *
 * @param learnMore today's new limit raised by this many moves (Anki's custom study), or 0.
 */
class DrillModel(
    val document: RepertoireDocument,
    val mode: DrillMode,
    val learnMore: Int = 0,
) {
    /** Called by the shell when Study leaves the back stack: free the core session. */
    fun close() {}
}
