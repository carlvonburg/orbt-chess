package org.orbtchess.orbt.ui.builder

import org.orbtchess.orbt.storage.NodeId
import org.orbtchess.orbt.storage.RepertoireDocument

/**
 * Build's state (`BuilderModel.swift`): a thin observable wrapper over the core's
 * `BuilderSession` that re-reads it when the document's revision changes. Made by the shell
 * before Build is shown and shared by its panes ([org.orbtchess.orbt.ui.components.BoardPane]).
 *
 * STUB: the constructor is the shell's contract; the Build screen fills in the rest.
 *
 * @param start the position to start from (null: the start of the repertoire).
 * @param showGaps open the gap list over the builder at first.
 */
class BuilderModel(
    val document: RepertoireDocument,
    val start: NodeId? = null,
    val showGaps: Boolean = false,
) {
    /** Called by the shell when Build leaves the back stack: free the core session. */
    fun close() {}
}
