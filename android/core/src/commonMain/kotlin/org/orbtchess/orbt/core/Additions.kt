package org.orbtchess.orbt.core

import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit

// Hand-written conveniences over the generated bindings (`opening_core.kt`), as
// `apple/OpeningCoreRust/Sources/OpeningCoreRust/Additions.swift`: names, conversions; no rules.

// MARK: Time

/** The hour the scheduling day rolls over, Anki's default. */
const val ROLLOVER_HOUR = 4

/**
 * "Today" for scheduling from the local calendar: days since 1 Jan 2020 (local time), rolling
 * over at 4 AM, and when the next day starts. The Rust core takes these numbers, as Anki takes
 * the UTC offset from its caller.
 */
fun schedTiming(
    nowMs: Long = System.currentTimeMillis(),
    rolloverHour: Int = ROLLOVER_HOUR,
    zone: ZoneId = ZoneId.systemDefault(),
): SchedTiming {
    val now = ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(nowMs), zone)
    val start = now.toLocalDate()
    val rolloverToday = ZonedDateTime.of(start, LocalTime.of(rolloverHour, 0), zone)
    val passed = !rolloverToday.isAfter(now)
    val nextDay = if (passed) rolloverToday.plusDays(1) else rolloverToday
    val days = ChronoUnit.DAYS.between(LocalDate.of(2020, 1, 1), start)
    return SchedTiming(
        daysElapsed = maxOf(0, if (passed) days else days - 1),
        nextDayAt = nextDay.toEpochSecond(),
        now = nowMs / 1000,
    )
}

/** Unix seconds when today started. */
val SchedTiming.dayStart: Long get() = nextDayAt - 86_400

/** Milliseconds since 1970, the core's timestamps. */
fun nowTimestamp(): Timestamp = System.currentTimeMillis()

// MARK: Chess

/** Square from file and rank (0-based), as `BoardSquare(file:rank:)` in Swift. */
fun boardSquare(file: Int, rank: Int): BoardSquare = BoardSquare((rank * 8 + file).toUByte())

val BoardSquare.file: Int get() = index.toInt() % 8
val BoardSquare.rank: Int get() = index.toInt() / 8
val BoardSquare.isLight: Boolean get() = (file + rank) % 2 == 1

/** Algebraic notation, e.g. "e4". */
val BoardSquare.notation: String get() = "${'a' + file}${rank + 1}"

val PlayedMove.from: BoardSquare get() = boardSquare(uci[0] - 'a', uci[1] - '1')
val PlayedMove.to: BoardSquare get() = boardSquare(uci[2] - 'a', uci[3] - '1')

val Side.opposite: Side get() = if (this == Side.WHITE) Side.BLACK else Side.WHITE
val Side.title: String get() = if (this == Side.WHITE) "White" else "Black"

// MARK: Training

/** Every due move: new, learning and to review. */
val Counts.total: Long get() = new + learning + review

/** Moves studied at least once (Anki's learning, young and mature). */
val Progress.studied: Long get() = learning + young + mature
val Progress.notStudied: Long get() = cards - studied

// MARK: Statistics (statistics and settings screens)

/** True retention by period, of the cards in [positions] if given (`retentionTable` in Swift). */
fun Graphs.retentionTable(positions: List<Epd>? = null): Map<RetentionPeriod, TrueRetention> =
    trueRetention(positions).associate { it.period to it.retention }

/** No reviews. */
fun emptyTrueRetention() = TrueRetention(0, 0, 0, 0)

val TrueRetention.young: Double? get() = retentionRateYoung(this)
val TrueRetention.mature: Double? get() = retentionRateMature(this)
val TrueRetention.total: Double? get() = retentionRateTotal(this)
val TrueRetention.count: Long get() = youngPassed + youngFailed + maturePassed + matureFailed

val ReviewCounts.total: Long get() = learn + relearn + young + mature + filtered

val CardCounts.total: Long get() = new + learn + relearn + young + mature + suspended

/** The range's name, from the core. */
val GraphRange.title: String get() = rangeTitle(this)

/** Days the range covers; 0 for all time. */
val GraphRange.days: Int get() = rangeDays(this).toInt()

val RetentionPeriod.title: String get() = retentionPeriodTitle(this)
