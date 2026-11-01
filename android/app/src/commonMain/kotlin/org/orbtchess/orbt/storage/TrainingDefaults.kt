package org.orbtchess.orbt.storage

import org.orbtchess.orbt.core.NewMoveOrder
import org.orbtchess.orbt.core.PracticeMode
import org.orbtchess.orbt.core.StudyDefaults
import org.orbtchess.orbt.core.ankiPreset
import org.orbtchess.orbt.platform.Settings

/** The default daily-practice preset (Anki's "Default" preset), edited in Settings. A
 *  repertoire can override the limits, the practice mode and the new move order. */
class TrainingDefaults(private val settings: Settings) {
    var newPerDay: Int
        get() = settings.getInt(NEW_PER_DAY_KEY) ?: preset.newPerDay.toInt()
        set(value) = settings.putInt(NEW_PER_DAY_KEY, value)

    var reviewsPerDay: Int
        get() = settings.getInt(REVIEWS_PER_DAY_KEY) ?: preset.reviewsPerDay.toInt()
        set(value) = settings.putInt(REVIEWS_PER_DAY_KEY, value)

    var practiceMode: PracticeMode
        get() = settings.getString(PRACTICE_MODE_KEY)?.let(::practiceMode) ?: PracticeMode.INDIVIDUAL_MOVES
        set(value) = settings.putString(PRACTICE_MODE_KEY, rawValue(value))

    var newMoveOrder: NewMoveOrder
        get() = settings.getString(NEW_MOVE_ORDER_KEY)?.let(::newMoveOrder) ?: NewMoveOrder.MOST_LIKELY_FIRST
        set(value) = settings.putString(NEW_MOVE_ORDER_KEY, rawValue(value))

    val studyDefaults: StudyDefaults
        get() = StudyDefaults(newPerDay.toLong(), reviewsPerDay.toLong(), practiceMode, newMoveOrder)

    companion object {
        const val NEW_PER_DAY_KEY = "training.newPerDay"
        const val REVIEWS_PER_DAY_KEY = "training.reviewsPerDay"
        const val PRACTICE_MODE_KEY = "training.practiceMode"
        const val NEW_MOVE_ORDER_KEY = "training.newMoveOrder"
        /** New moves added to today's limit by "Learn N New Moves" (Anki's custom study). */
        const val LEARN_MORE_COUNT = 5

        /** Anki's preset values (steps, retention), from the core. */
        val preset = ankiPreset()

        /** The stored names, the Swift app's `PracticeMode.rawValue`. */
        fun rawValue(mode: PracticeMode): String = when (mode) {
            PracticeMode.INDIVIDUAL_MOVES -> "individualMoves"
            PracticeMode.COMPLETE_LINES_EVERY_TIME -> "completeLinesEveryTime"
            PracticeMode.COMPLETE_LINES_ONCE_PER_SESSION -> "completeLinesOncePerSession"
        }

        fun practiceMode(rawValue: String): PracticeMode? = PracticeMode.entries.firstOrNull { rawValue(it) == rawValue }

        /** The stored names, the Swift app's `NewMoveOrder.rawValue`. */
        fun rawValue(order: NewMoveOrder): String = when (order) {
            NewMoveOrder.MOST_LIKELY_FIRST -> "mostLikelyFirst"
            NewMoveOrder.ONE_OPENING_AT_A_TIME -> "oneOpeningAtATime"
        }

        fun newMoveOrder(rawValue: String): NewMoveOrder? = NewMoveOrder.entries.firstOrNull { rawValue(it) == rawValue }
    }
}
