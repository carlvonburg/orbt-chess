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
