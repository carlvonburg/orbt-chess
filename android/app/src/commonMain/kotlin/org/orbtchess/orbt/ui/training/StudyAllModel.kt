package org.orbtchess.orbt.ui.training

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.DrillMode
import org.orbtchess.orbt.storage.RepertoireEntry

/**
 * Study All (`StudyAllModel` in LibraryScreens.swift): today's moves of every repertoire that has
 * some, one repertoire after another in the library's order, each with its own [DrillModel].
 * Unlike an Anki parent deck, reviews are not mixed across repertoires, so each line stays
 * within one PGN.
 */
class StudyAllModel(val app: AppModel, val entries: List<RepertoireEntry>) {
    private val scope = MainScope()
    private val leaving = mutableListOf<DrillModel>()

    var index by mutableIntStateOf(0)
        private set

    /** The repertoire studied now, once its document is open. */
    var drill: DrillModel? by mutableStateOf(null)
        private set

    val next: RepertoireEntry? get() = entries.getOrNull(index + 1)

    /** Opens the current repertoire's document and makes its drill (called by the shell before showing it). */
    suspend fun openCurrent() {
        val entry = entries.getOrNull(index)
        val document = entry?.let { app.documents.open(it) }
        drill = document?.let { DrillModel(it, DrillMode.Study) }
    }

    /** On to the next repertoire. */
    suspend fun advance() {
        if (next == null) return
        val previous = drill
        index += 1
        drill = null
        // Its screen is leaving: closed once it has gone.
        previous?.let { scope.launch { delay(1_000); it.close() } }
        previous?.let { leaving += it }
        openCurrent()
    }

    /** Starts the next repertoire (the finished screen's Continue). */
    fun startNext() {
        scope.launch { advance() }
    }

    /** Called by the shell when Study All leaves the back stack. */
    fun close() {
        drill?.close()
        leaving.forEach { it.close() }
        scope.cancel()
    }
}
