package org.orbtchess.orbt.ui.statistics

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Start
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.core.GraphRange
import org.orbtchess.orbt.core.Graphs
import org.orbtchess.orbt.core.ReviewCounts
import org.orbtchess.orbt.core.RetentionPeriod
import org.orbtchess.orbt.core.StageCounts
import org.orbtchess.orbt.core.TrueRetention
import org.orbtchess.orbt.core.WeakMove
import org.orbtchess.orbt.core.count
import org.orbtchess.orbt.core.days
import org.orbtchess.orbt.core.emptyTrueRetention
import org.orbtchess.orbt.core.mature
import org.orbtchess.orbt.core.retentionTable
import org.orbtchess.orbt.core.title
import org.orbtchess.orbt.core.total
import org.orbtchess.orbt.core.young
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color
import java.time.LocalDate
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit

// The cards of the Statistics screen (`StatisticsView.swift`), each answering one question with
// the chart that suits it. Anki's graphs underneath; FSRS's internals are left out.

/** A row of a card's header: the number on the leading side, a note on the trailing side. */
@Composable
private fun Header(lead: @Composable () -> Unit, trail: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.weight(1f)) { lead() }
        trail()
    }
}

@Composable
private fun Note(text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Text(text, style = tabularDigits(MaterialTheme.typography.bodySmall), color = color, textAlign = TextAlign.End)
}

/** Every other bar labelled, spread over at most [max] labels. */
private fun spreadLabels(dates: List<LocalDate>, unit: BinUnit, max: Int = 4): Map<Int, String> {
    if (dates.isEmpty()) return emptyMap()
    val step = maxOf(1, (dates.size + max - 1) / max)
    return dates.indices.filter { it % step == 0 }.associateWith { StatDay.axisLabel(dates[it], unit) }
}

// MARK: Streak

/**
 * The streak and Anki's calendar: a square a day, darker the more answers, from the week you
 * started (16 to 26 weeks, so it is never mostly empty); tapping a day shows its answers.
 */
@Composable
internal fun StreakCard(graphs: Graphs) {
    var selected by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    val streak = remember(graphs) { graphs.streak() }
    val counts = remember(graphs) {
        graphs.reviews().count.mapKeys { it.key.toInt() }.mapValues { it.value.total }.filterValues { it > 0 }
    }
    val firstDay = minOf(counts.keys.minOrNull() ?: 0, 0)
    val weeks = (-firstDay / 7 + 2).coerceIn(16, 26)
    val cells = remember(counts, weeks) { calendarCells(counts, weeks) }
    val maxCount = maxOf(cells.maxOfOrNull { it.count } ?: 1, 1)
    val studied = cells.count { it.count > 0 }
    val months = cells.filter { it.date.dayOfMonth == 1 }.associate { it.week to it.date.format(DateTimeFormatter.ofPattern("MMM")) }
    val chosen = cells.firstOrNull { it.week to it.weekday == selected }
    val todo = ThemeColor.todo
    val todoColor = todo.color
    val empty = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.15f)
    StatCard("Streak", Icons.Filled.LocalFireDepartment, color = todo) {
        Header({ StatValue(number(streak.current), daysUnit(streak.current)) }) {
            when {
                chosen != null -> Note("${chosen.date.format(DateTimeFormatter.ofPattern("EEE d MMM"))}: ${answersText(chosen.count)}")
                !streak.studiedToday && streak.current > 0 -> Note("Study today to keep it", todoColor)
            }
        }
        CalendarGrid(
            weeks = weeks,
            cells = cells.map {
                Triple(
                    it.week,
                    it.weekday,
                    if (it.count > 0) todoColor.copy(alpha = (0.3f + 0.7f * it.count / maxCount) * todoColor.alpha) else empty,
                )
            },
            weekLabels = months,
            description = "Studied on $studied of the last ${cells.size} days",
            selected = selected,
            onSelect = { selected = it },
        )
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            Metric("Longest streak", number(streak.longest), daysUnit(streak.longest))
            Metric("Days studied", number(studied), "of ${1 - firstDay} since you started")
        }
    }
}

private class CalendarCell(val week: Int, val weekday: Int, val date: LocalDate, val count: Long)

/** Up to today, the weeks starting on the locale's first weekday. */
private fun calendarCells(counts: Map<Int, Long>, weeks: Int): List<CalendarCell> {
    val today = LocalDate.now()
    val thisWeek = StatDay.start(today, BinUnit.Week)
    val result = mutableListOf<CalendarCell>()
    for (week in 0 until weeks) {
        for (weekday in 0 until 7) {
            val date = thisWeek.plusDays(((week - weeks + 1) * 7 + weekday).toLong())
            if (date.isAfter(today)) continue
            val day = ChronoUnit.DAYS.between(today, date).toInt()
            result += CalendarCell(week, weekday, date, counts[day] ?: 0)
        }
    }
    return result
}

// MARK: Reviews

/** Anki's Reviews graph: answers per day (or week, month) by kind, and its table in a line. */
@Composable
internal fun ReviewsCard(graphs: Graphs, range: GraphRange) {
    var selected by remember { mutableStateOf<Int?>(null) }
    var showTime by remember { mutableStateOf(false) }
    LaunchedEffect(range) { selected = null }
    val summary = remember(graphs, range) { graphs.reviewsSummary(range) }
    val first = 1 - summary.periodDays.toInt()
    val unit = range.binUnit
    val reviews = remember(graphs) { graphs.reviews() }
    val bins = StatDay.bins(first, 0, unit)
    // Each bar's totals by kind.
    val sums = remember(reviews, showTime, first, unit) {
        val days = if (showTime) reviews.time else reviews.count
        val result = Array(bins.size) { LongArray(ReviewKind.entries.size) }
        val index = bins.withIndex().associate { it.value to it.index }
        for ((day, counts) in days) {
            if (day.toInt() !in first..0) continue
            val i = index[StatDay.bin(day.toInt(), unit)] ?: continue
            for (kind in ReviewKind.entries) result[i][kind.ordinal] += kind.value(counts)
        }
        result
    }
    val totals = ReviewKind.entries.associateWith { kind -> sums.sumOf { it[kind.ordinal] } }
    fun value(n: Long) = if (showTime) durationText(n) else number(n)
    val colors = ReviewKind.entries.map { it.color.color }
    StatCard("Reviews", Icons.Filled.BarChart) {
        Header({
            val bin = selected
            if (bin != null) {
                Column {
                    StatValue(value(sums[bin].sum()), if (showTime) null else "answers")
                    Note(StatDay.title(bins[bin], unit))
                }
            } else {
                val total = if (showTime) summary.millis else summary.answers
                StatValue(value(total / maxOf(summary.periodDays, 1)), if (showTime) "a day" else "answers a day")
            }
        }) {
            SingleChoiceSegmentedButtonRow {
                listOf(false to "Answers", true to "Time").forEachIndexed { i, (time, label) ->
                    SegmentedButton(
                        selected = showTime == time,
                        onClick = { showTime = time },
                        shape = SegmentedButtonDefaults.itemShape(i, 2),
                        icon = {},
                        label = { Text(label) },
                    )
                }
            }
        }
        val top = niceMax((sums.maxOfOrNull { it.sum() } ?: 0L).toDouble().let { if (showTime) it / 60_000 else it })
        BarChart(
            bars = sums.map { bar ->
                ReviewKind.entries.map { kind ->
                    val v = bar[kind.ordinal].toDouble()
                    (if (showTime) v / 60_000 else v) to colors[kind.ordinal]
                }
            },
            xLabels = spreadLabels(bins, unit),
            description = "${if (showTime) "Minutes" else "Answers"} by ${unit.name.lowercase()}, ${range.periodTitle.lowercase()}",
            top = top,
            axis = countAxis(top) { if (showTime) "${it.toLong()}m" else number(it.toLong()) },
            selected = selected,
            onSelect = { selected = it },
        )
        Legend {
            for (kind in ReviewKind.entries) {
                val total = totals[kind] ?: 0
                if (total > 0) LegendItem(kind.title, kind.color, value(total))
            }
        }
        Footnote(
            "${range.periodTitle}: studied ${summary.daysStudied} of ${summary.periodDays} days · " +
                "${answersText(summary.answers)} in ${durationText(summary.millis)}" +
                if (summary.answers > 0) " · ${durationText(summary.millis / summary.answers)} an answer" else "",
        )
    }
}

// MARK: Moves

/** Bottom to top: what is learned for good first. */
private val stages = listOf(MoveGroup.Mature, MoveGroup.Young, MoveGroup.Relearning, MoveGroup.Learning)

private fun StageCounts?.count(group: MoveGroup): Long = when {
    this == null -> 0
    group == MoveGroup.Learning -> learning
    group == MoveGroup.Relearning -> relearning
    group == MoveGroup.Young -> young
    group == MoveGroup.Mature -> mature
    else -> 0
}

/**
 * The repertoire growing into memory: Anki's card counts day by day over the period, so you see
 * moves go from learning to young to mature; then where all of them stand now.
 */
@Composable
internal fun MovesCard(graphs: Graphs, range: GraphRange) {
    var selected by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(range) { selected = null }
    val c = remember(graphs) { graphs.cardCounts() }
    val days = remember(graphs) { graphs.stagesByDay() }
    val byDay = remember(days) { days.associateBy { it.day.toInt() } }
    val first = if (range == GraphRange.ALL) minOf(days.firstOrNull()?.day?.toInt() ?: 0, 0) else 1 - range.days
    val start = byDay[first] ?: StageCounts(first.toLong(), 0, 0, 0, 0)
    val today = byDay[0] ?: start
    val dayList = (first..0).toList()
    val started = remember(graphs, first) {
        graphs.firstStudied().filterKeys { it.toInt() in first..0 }.values.sum()
    }
    StatCard("Moves", Icons.Filled.Layers, color = ThemeColor.learned) {
        val chosen = selected?.let { byDay[dayList[it]] }
        Header({
            StatValue(number((chosen ?: today).let { it.young + it.mature }), "learned")
        }) {
            if (chosen != null) {
                Note(
                    "${StatDay.title(StatDay.date(chosen.day.toInt()), BinUnit.Day)}: ${chosen.mature} mature, " +
                        "${chosen.young} young, ${chosen.learning + chosen.relearning} learning",
                )
            } else {
                Note("${number(today.mature)} mature (${signed(today.mature - start.mature)}), ${range.periodTitle.lowercase()}")
            }
        }
        val dates = dayList.map { StatDay.date(it) }
        AreaChart(
            points = dayList.map { day -> stages.map { byDay[day].count(it).toDouble() } },
            colors = stages.map { it.color.color },
            xLabels = spreadLabels(dates, BinUnit.Day).let { labels ->
                // The last point is today: label it rather than a day just before.
                if (dates.size > 1) labels.filterKeys { it < dates.size - dates.size / 8 } + (dates.size - 1 to "Today") else labels
            },
            description = "Moves learned day by day, ${range.periodTitle.lowercase()}: " +
                "${today.mature} mature, ${today.young} young, ${today.learning + today.relearning} learning today",
            selected = selected,
            onSelect = { selected = it },
        )
        Footnote("Learned: young or mature. ${signed(started)} moves started, ${range.periodTitle.lowercase()}.")
        HorizontalDivider()
        Caption("Now")
        MoveGroupsBar(c)
        Legend {
            for (group in MoveGroup.entries) {
                val n = group.count(c)
                if (n > 0) LegendItem(group.title, group.color, number(n))
            }
        }
        Footnote(
            "Young moves are shown again within 3 weeks, mature ones in 3 weeks or more. " +
                "Suspended: below alternative moves; they keep their progress.",
        )
    }
}

// MARK: Upcoming

/** Anki's Future Due graph; overdue moves are part of today's bar. */
@Composable
internal fun UpcomingCard(graphs: Graphs, range: GraphRange) {
    var selected by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(range) { selected = null }
    val summary = remember(graphs, range) { graphs.futureDueSummary(range) }
    val unit = range.binUnit
    val last = summary.periodDays.toInt()
    val bins = StatDay.bins(0, maxOf(last - 1, 0), unit)
    val due = remember(graphs) { graphs.futureDue().dueByDay }
    // Each bar: overdue (today's bar only), then due.
    val sums = remember(due, last, unit) {
        val index = bins.withIndex().associate { it.value to it.index }
        val result = Array(bins.size) { LongArray(2) }
        for ((day, count) in due) {
            val d = day.toInt()
            when {
                d < 0 -> result[0][0] += count
                d < last -> index[StatDay.bin(d, unit)]?.let { result[it][1] += count }
            }
        }
        result
    }
    val wrong = ThemeColor.wrong
    val colors = listOf(wrong.color, MaterialTheme.colorScheme.primary)
    StatCard("Upcoming", Icons.Filled.CalendarMonth) {
        val bin = selected
        if (bin != null) {
            Header({ StatValue(number(sums[bin].sum()), "due") }) { Note(StatDay.title(bins[bin], unit)) }
        } else {
            Header({ StatValue(number(summary.dueTomorrow), "due tomorrow") }) { Note(range.nextTitle) }
        }
        BarChart(
            bars = sums.map { listOf(it[0].toDouble() to colors[0], it[1].toDouble() to colors[1]) },
            xLabels = spreadLabels(bins, unit),
            description = "Moves due by ${unit.name.lowercase()}, ${range.nextTitle.lowercase()}: ${movesText(summary.total)}",
            selected = selected,
            onSelect = { selected = it },
        )
        if (summary.overdue > 0) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.ErrorOutline, contentDescription = null, tint = wrong.color, modifier = Modifier.padding(0.dp))
                Text("${movesText(summary.overdue)} overdue", style = MaterialTheme.typography.bodySmall, color = wrong.color)
            }
        }
        Footnote(
            "${movesText(summary.total)} · ${number(Math.round(summary.total.toDouble() / maxOf(last, 1)))} a day · " +
                "daily load ${number(summary.dailyLoad)}",
        )
    }
}

// MARK: Retention

/** Anki's True Retention table. */
@Composable
internal fun RetentionCard(graphs: Graphs) {
    val table = remember(graphs) { graphs.retentionTable() }
    val month = table[RetentionPeriod.MONTH] ?: emptyTrueRetention()
    StatCard("Retention", Icons.Filled.Verified, color = ThemeColor.correct) {
        Header({ StatValue(percent(month.total), "remembered") }) { Note(RetentionPeriod.MONTH.title) }
        Column {
            val caption = tabularDigits(MaterialTheme.typography.labelMedium)
            val body = tabularDigits(MaterialTheme.typography.bodyMedium)
            val secondary = MaterialTheme.colorScheme.onSurfaceVariant
            RetentionRow("", "Young", "Mature", "Total", "Reviews", caption, secondary, secondary)
            for (period in RetentionPeriod.entries) {
                val r = table[period] ?: emptyTrueRetention()
                HorizontalDivider(Modifier.padding(vertical = 4.dp))
                RetentionRow(
                    period.title, percent(r.young), percent(r.mature), percent(r.total), number(r.count),
                    body, secondary, MaterialTheme.colorScheme.onSurface,
                )
            }
        }
        Footnote("Reviews a day or more after the last one, answered correctly. FSRS aims for your desired retention (90% by default).")
    }
}

@Composable
private fun RetentionRow(
    title: String,
    young: String,
    mature: String,
    total: String,
    reviews: String,
    style: androidx.compose.ui.text.TextStyle,
    secondary: Color,
    primary: Color,
) {
    Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}) {
        Text(title, Modifier.weight(1.6f), style = style, color = primary)
        Text(young, Modifier.weight(1f), style = style, color = secondary, textAlign = TextAlign.End)
        Text(mature, Modifier.weight(1f), style = style, color = secondary, textAlign = TextAlign.End)
        Text(total, Modifier.weight(1f), style = style.copy(fontWeight = FontWeight.SemiBold), color = primary, textAlign = TextAlign.End)
        Text(reviews, Modifier.weight(1.1f), style = style, color = secondary, textAlign = TextAlign.End)
    }
}

/** True retention, all time, for each opening (one repertoire) or each repertoire (all). */
@Composable
internal fun RetentionRowsCard(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    rows: List<Pair<String, TrueRetention>>,
    footnote: String,
) {
    StatCard(title, icon, color = ThemeColor.correct) {
        val fill = ThemeColor.correct.color
        for ((name, r) in rows) {
            Column(
                Modifier.clearAndSetSemantics { contentDescription = "$name: ${percent(r.total)}, ${number(r.count)} reviews" },
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(name, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Note("${percent(r.total)} · ${r.count}")
                }
                LinearProgressIndicator(
                    progress = { (r.total ?: 0.0).toFloat() },
                    modifier = Modifier.fillMaxWidth().height(8.dp),
                    color = fill,
                    trackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                    strokeCap = StrokeCap.Round,
                    gapSize = 0.dp,
                    drawStopIndicator = {},
                )
            }
        }
        Footnote(footnote)
    }
}

// MARK: Time of day

private fun hourTitle(hour: Int): String =
    LocalTime.of(hour % 24, 0).format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT))

/**
 * Anki's Hourly Breakdown: answers by hour (bars), and the share answered correctly (the line,
 * on the leading axis).
 */
@Composable
internal fun TimeOfDayCard(graphs: Graphs, range: GraphRange) {
    var selected by remember { mutableStateOf<Int?>(null) }
    val hours = remember(graphs, range) { graphs.hours(range) }
    // The busiest hour at the top, so 100% correct lines up with it.
    val top = (hours.maxOfOrNull { it.total } ?: 1L).coerceAtLeast(1L).toDouble()
    val busiest = hours.indices.maxByOrNull { hours[it].total }
    val bar = MaterialTheme.colorScheme.primary
    val correct = ThemeColor.correct.color
    StatCard("Time of Day", Icons.Filled.Schedule) {
        val hour = selected ?: busiest
        if (hour != null && hours[hour].total > 0) {
            val h = hours[hour]
            Column {
                StatValue(percent(h.correct.toDouble() / h.total), "correct")
                Footnote("${if (selected == null) "Most answers: " else ""}${hourTitle(hour)}–${hourTitle(hour + 1)}, ${answersText(h.total)}")
            }
        } else {
            Footnote("No answers in this period.")
        }
        BarChart(
            bars = hours.map { listOf(it.total.toDouble() to bar) },
            xLabels = listOf(0, 6, 12, 18).associateWith { hourTitle(it) },
            description = "Answers and the share correct by hour of the day, ${range.periodTitle.lowercase()}",
            top = top,
            axis = countAxis(top) { number(Math.round(it)) },
            leadingAxis = listOf(0.0, 0.5, 1.0).map { AxisLabel(it * top, percent(it)) },
            selected = selected,
            onSelect = { selected = it },
            overlay = { plot, slot ->
                lineThrough(
                    hours.withIndex().filter { it.value.total > 0 }.map { it.index to it.value.correct.toDouble() / it.value.total },
                    correct, plot, slot,
                )
            },
        )
        Legend {
            LegendItem("Answers", ThemeColor.built, "")
            LegendItem("Correct", ThemeColor.correct, "")
        }
    }
}

// MARK: Recall

/** Retrievability in 10% bins. */
private fun retrievabilityBins(bins: Map<Long, Long>): LongArray {
    val result = LongArray(10)
    for ((p, count) in bins) result[(minOf(p, 99) / 10).toInt().coerceAtLeast(0)] += count
    return result
}

/**
 * FSRS's average recall now, the expected recall in your games (one repertoire), and Anki's
 * Answer Buttons as correct answers by stage.
 */
@Composable
internal fun RecallCard(graphs: Graphs, range: GraphRange, expected: Double?) {
    val r = remember(graphs) { graphs.retrievability() }
    val b = remember(graphs, range) { graphs.buttons(range) }
    StatCard("Recall", Icons.Filled.Psychology) {
        if (r.bins.isEmpty() && expected == null) {
            Footnote("How likely you are to recall each move, once you have studied some.")
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(32.dp)) {
                if (r.bins.isNotEmpty()) {
                    Column(Modifier.semantics(mergeDescendants = true) {}) {
                        StatValue(percent(r.average / 100), "now")
                        Caption("Your studied moves")
                    }
                }
                if (expected != null) {
                    Column(Modifier.semantics(mergeDescendants = true) {}) {
                        StatValue(percent(expected), "in your games")
                        Caption("Weighted by how often they come up")
                    }
                }
            }
        }
        if (r.bins.isNotEmpty()) {
            val bins = retrievabilityBins(r.bins)
            val wrong = ThemeColor.wrong.color
            val tint = MaterialTheme.colorScheme.primary
            BarChart(
                bars = bins.mapIndexed { i, n -> listOf(n.toDouble() to if (i < 7) wrong else tint) },
                xLabels = mapOf(0 to "0%", 5 to "50%", 7 to "70%", 9 to "90%"),
                labelAtStart = true,
                height = 110.dp,
                description = "Moves by how likely you are to recall them, in steps of 10%; ${number(bins.take(7).sum())} below 70%",
            )
            Footnote(
                "You would recall about ${movesText(Math.round(r.sum))} right now; below 70% in red." +
                    if (expected == null) "" else " In your games, moves you have not studied count as forgotten.",
            )
        }
        HorizontalDivider()
        Caption("Correct answers, ${range.periodTitle.lowercase()}")
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            for ((name, counts) in listOf("Learning" to b.learning, "Young" to b.young, "Mature" to b.mature)) {
                val total = counts.sum()
                val wrong = counts.firstOrNull() ?: 0
                Metric(name, if (total > 0) percent((total - wrong).toDouble() / total) else "—")
            }
        }
        Footnote("Wrong: a wrong move, a hint or looking the move up.")
    }
}

// MARK: Intervals

/** Anki's buckets, coarser further out. */
private val intervalBins = listOf(
    "1d" to 0..1, "2d" to 2..2, "3d" to 3..3, "4–7d" to 4..7, "1–2w" to 8..14,
    "2–3w" to 15..20, "3–4w" to 21..30, "1–3m" to 31..90, "3m+" to 91..Int.MAX_VALUE,
)

/** Anki's Review Intervals: how far ahead each move is scheduled. */
@Composable
internal fun IntervalsCard(graphs: Graphs) {
    val intervals = remember(graphs) { graphs.intervals().mapKeys { it.key.toInt() } }
    val total = intervals.values.sum()
    StatCard("Intervals", Icons.Filled.Start) {
        if (total == 0L) {
            Footnote("The days until each move comes back, once you review some.")
        } else {
            val mean = intervals.entries.sumOf { it.key.toLong() * it.value }.toDouble() / total
            val withinWeek = intervals.filterKeys { it <= 7 }.values.sum()
            StatValue(if (mean < 10) "%.1f".format(mean).removeSuffix(".0") else number(Math.round(mean)), "days on average")
            val tint = MaterialTheme.colorScheme.primary
            val counts = intervalBins.map { (_, days) -> intervals.filterKeys { it in days }.values.sum() }
            BarChart(
                bars = counts.map { listOf(it.toDouble() to tint) },
                xLabels = intervalBins.withIndex().filter { it.index % 2 == 0 }.associate { it.index to it.value.first },
                height = 120.dp,
                description = "Moves by days until they come back: " +
                    intervalBins.zip(counts).joinToString { (bin, n) -> "${bin.first} ${number(n)}" },
            )
            Footnote(
                "The days until each move comes back. ${percent(withinWeek.toDouble() / total)} come back within a week; " +
                    "mature moves at 21 days or more.",
            )
        }
    }
}

// MARK: Weakest moves

/** The moves you forget most, each opening Build at it. */
@Composable
internal fun WeakestMovesCard(model: StatisticsModel, open: (WeakMove) -> Unit) {
    val moves = remember(model.cards) { model.weakestMoves(limit = 6) }
    StatCard("Weakest Moves", Icons.Filled.Warning, color = ThemeColor.wrong) {
        if (moves.isEmpty()) {
            Footnote("Nothing forgotten yet.")
        } else {
            Column {
                moves.forEachIndexed { index, move ->
                    if (index > 0) HorizontalDivider()
                    if (model.node(move.epd) != null) WeakMoveRow(model, move) { open(move) }
                }
            }
            Footnote("Leeches (the bug) first, then the moves you forget most.")
        }
    }
}

/** A weak move: its line, lapses and recall. Opens Build at it. */
@Composable
private fun WeakMoveRow(model: StatisticsModel, move: WeakMove, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(model.lineText(move.epd), maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Text(
                "${move.lapses} ${if (move.lapses == 1L) "lapse" else "lapses"} · recall ${percent(move.retrievability)}",
                style = tabularDigits(MaterialTheme.typography.bodySmall),
            )
        },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (move.leech) Icon(Icons.Filled.BugReport, contentDescription = "Leech", tint = ThemeColor.todo.color)
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null)
            }
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.clickable(onClick = onClick),
    )
}

/** The icons of the per-opening and per-repertoire retention cards. */
internal object RetentionIcons {
    val branches get() = Icons.Filled.AccountTree
    val repertoires get() = Icons.AutoMirrored.Filled.LibraryBooks
}
