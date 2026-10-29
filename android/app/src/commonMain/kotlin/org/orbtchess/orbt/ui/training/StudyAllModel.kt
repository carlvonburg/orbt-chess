package org.orbtchess.orbt.ui.training

import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireEntry

/**
 * Study All (`StudyAllModel` in LibraryScreens.swift): today's moves of every repertoire that has
 * some, one repertoire after another, each with its own [DrillModel].
 *
 * STUB: the constructor is the shell's contract; the Study All screen fills in the rest
 * (`drill`, `next`, `advance()`).
 */
class StudyAllModel(val app: AppModel, val entries: List<RepertoireEntry>) {
    /** Opens the first repertoire's document and makes its drill (called by the shell before showing it). */
    suspend fun openCurrent() {}

    /** Called by the shell when Study All leaves the back stack. */
    fun close() {}
}
