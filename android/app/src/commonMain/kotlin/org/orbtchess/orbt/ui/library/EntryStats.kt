package org.orbtchess.orbt.ui.library

import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.Counts
import org.orbtchess.orbt.core.Graphs
import org.orbtchess.orbt.core.LibrarySidecar
import org.orbtchess.orbt.core.Progress
import org.orbtchess.orbt.core.RevlogEntry
import org.orbtchess.orbt.core.Streak
import org.orbtchess.orbt.core.Today
import org.orbtchess.orbt.core.schedTiming
import org.orbtchess.orbt.core.total
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.storage.RepertoireEntry
import org.orbtchess.orbt.storage.StudyLog
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit
import java.util.TimeZone

/**
 * Progress of one repertoire (`EntryStats` in LibraryView.swift): live from the open document,
 * else from the sidecar. Reading it through an open document redraws the view when it changes.
 */
class EntryStats private constructor(
    val completion: Double = 0.0,
    val gaps: Int = 0,
    val savedMoves: Int = 0,
    val progress: Progress = Progress(0, 0, 0, 0, 0),
    val counts: Counts = Counts(0, 0, 0),
    /** Learning moves waiting for a later step today (unix seconds). */
    val laterLearning: List<Long> = emptyList(),
    val dueTomorrow: Int = 0,
    /** Unix seconds. */
    val nextDue: Long? = null,
) {
    companion object {
        fun of(document: RepertoireDocument): EntryStats {
            val root = document.coverage.root
            val timing = schedTiming()
            return EntryStats(
                completion = root?.completion ?: 0.0,
                gaps = (root?.gapCount ?: 0L).toInt(),
                savedMoves = document.savedMoveCount,
                progress = document.learningProgress(),
                counts = document.studyCounts(timing),
                laterLearning = document.sidecar.laterLearningDues(timing),
                dueTomorrow = document.sidecar.dueTomorrow(timing),
                nextDue = document.sidecar.nextDue(timing),
            )
        }

        fun of(entry: RepertoireEntry, app: AppModel): EntryStats =
            app.documents.documents[entry.id]?.let { of(it) } ?: of(entry.sidecar, app)

        private fun of(sidecar: LibrarySidecar?, app: AppModel): EntryStats {
            if (sidecar == null) return EntryStats()
            val timing = schedTiming()
            val summary = sidecar.summary()
            return EntryStats(
                completion = summary?.completion ?: 0.0,
                gaps = (summary?.gapCount ?: 0L).toInt(),
                // Older summaries have no move count: anything with your moves has saved moves.
                savedMoves = (summary?.let { it.savedMoveCount ?: it.cardCount } ?: 0L).toInt(),
                progress = sidecar.estimatedProgress(),
                counts = sidecar.estimatedStudyCounts(
                    app.training.newPerDay.toLong(), app.training.reviewsPerDay.toLong(), timing,
                ),
                laterLearning = sidecar.laterLearningDues(timing),
                dueTomorrow = sidecar.dueTomorrow(timing).toInt(),
                nextDue = sidecar.nextDue(timing),
            )
        }
    }
}

/** Today's answers and the study streak across all repertoires (`LibraryTodayModel`), read from their review logs. */
class TodaySummary(val today: Today?, val streak: Streak) {
    companion object {
        val empty = TodaySummary(null, Streak(0, 0, false))

        suspend fun load(app: AppModel): TodaySummary {
            val revlog = mutableListOf<RevlogEntry>()
            for (entry in app.library.entries) {
                if (!entry.needsSetup) revlog += StudyLog.revlog(entry, app.documents)
            }
            val offset = TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000L
            return Graphs(emptyList(), 0, 0, revlog, schedTiming(), offset).use {
                TodaySummary(it.today(), it.streak())
            }
        }
    }
}

/** Repertoires with moves due today, in list order (Study All's). */
internal fun studyAllEntries(app: AppModel): List<String> =
    app.library.entries.filter { !it.needsSetup && EntryStats.of(it, app).counts.total > 0 }.map { it.id }

// MARK: Dates as the library shows them

private fun zoned(unixSeconds: Long): ZonedDateTime = Instant.ofEpochSecond(unixSeconds).atZone(ZoneId.systemDefault())

/** Whether a time falls on today's calendar date. */
internal fun isToday(unixSeconds: Long): Boolean = zoned(unixSeconds).toLocalDate() == LocalDate.now()

/** A time of day, "14:30" or "2:30 PM" as the locale writes it. */
internal fun shortTime(unixSeconds: Long): String =
    zoned(unixSeconds).toLocalTime().format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT))

private fun daysFromToday(unixSeconds: Long): Long = ChronoUnit.DAYS.between(LocalDate.now(), zoned(unixSeconds).toLocalDate())

/** A time today, "Tomorrow", or "In N days" (`LibraryRow.nextStudyText`). */
internal fun nextStudyText(unixSeconds: Long): String {
    if (isToday(unixSeconds)) return shortTime(unixSeconds)
    val days = daysFromToday(unixSeconds)
    return if (days <= 1) "Tomorrow" else "In $days days"
}

/** "today", "tomorrow", "in 3 days" (Swift's named relative date). */
internal fun relativeDay(unixSeconds: Long): String = when (val days = daysFromToday(unixSeconds)) {
    in Long.MIN_VALUE..0 -> "today"
    1L -> "tomorrow"
    else -> "in $days days"
}
