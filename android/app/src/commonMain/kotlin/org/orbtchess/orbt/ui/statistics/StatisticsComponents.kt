package org.orbtchess.orbt.ui.statistics

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.core.CardCounts
import org.orbtchess.orbt.core.GraphRange
import org.orbtchess.orbt.core.ReviewCounts
import org.orbtchess.orbt.ui.components.SegmentedBar
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color
import java.text.NumberFormat
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit
import java.time.temporal.TemporalAdjusters
import java.time.temporal.WeekFields
import java.util.Locale
import kotlin.math.roundToLong

// The building blocks of the Statistics screen (`StatisticsComponents.swift`): a card names its
// subject with a symbol, leads with one number and shows the chart that answers it.

/** A card of the Statistics grid: Material's card, titled with its subject. */
@Composable
internal fun StatCard(
    title: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    color: ThemeColor? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            val tint = color?.color ?: MaterialTheme.colorScheme.primary
            Row(
                Modifier.semantics(mergeDescendants = true) { heading() },
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
                Text(title, style = MaterialTheme.typography.titleSmall, color = tint)
            }
            content()
        }
    }
}

/** A number with its unit smaller and secondary (Health's style in the Swift app). */
@Composable
internal fun StatValue(value: String, unit: String? = null, large: Boolean = true, modifier: Modifier = Modifier) {
    val style = if (large) MaterialTheme.typography.headlineMedium else MaterialTheme.typography.titleLarge
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    Text(
        buildAnnotatedString {
            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(value) }
            if (unit != null) {
                append(" ")
                withStyle(MaterialTheme.typography.titleSmall.toSpanStyle().copy(color = secondary)) { append(unit) }
            }
        },
        style = tabularDigits(style),
        modifier = modifier,
    )
}

/** A small metric in a row of several. */
@Composable
internal fun Metric(title: String, value: String, unit: String? = null) {
    Column(Modifier.semantics(mergeDescendants = true) {}) {
        Text(title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        StatValue(value, unit, large = false)
    }
}

/** A line of facts under a chart. */
@Composable
internal fun Footnote(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = tabularDigits(MaterialTheme.typography.bodySmall),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier,
    )
}

/** A small caption above part of a card ("Now"). */
@Composable
internal fun Caption(text: String) {
    Text(text, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** A colored key with its name and value, so color is never the only cue. */
@Composable
internal fun LegendItem(name: String, color: ThemeColor, value: String) {
    val fill = color.color
    Row(
        Modifier.clearAndSetSemantics { contentDescription = "$name $value" },
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Canvas(Modifier.size(8.dp)) { drawCircle(fill) }
        Text(name, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = tabularDigits(MaterialTheme.typography.labelMedium))
    }
}

/** Legend items that wrap onto more lines when they don't fit. */
@Composable
internal fun Legend(content: @Composable () -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        content()
    }
}

// MARK: Ranges

/** Health's period names, as the Swift app shows them. */
internal val GraphRange.shortTitle: String
    get() = when (this) {
        GraphRange.WEEK -> "W"
        GraphRange.MONTH -> "M"
        GraphRange.THREE_MONTHS -> "3M"
        GraphRange.YEAR -> "Y"
        GraphRange.ALL -> "All"
    }

internal val GraphRange.periodTitle: String
    get() = when (this) {
        GraphRange.WEEK -> "Last 7 days"
        GraphRange.MONTH -> "Last 30 days"
        GraphRange.THREE_MONTHS -> "Last 3 months"
        GraphRange.YEAR -> "Last year"
        GraphRange.ALL -> "All time"
    }

internal val GraphRange.nextTitle: String
    get() = when (this) {
        GraphRange.WEEK -> "Next 7 days"
        GraphRange.MONTH -> "Next 30 days"
        GraphRange.THREE_MONTHS -> "Next 3 months"
        GraphRange.YEAR -> "Next year"
        GraphRange.ALL -> "Everything due"
    }

/** The bars of a chart over a range: days, weeks for three months, months beyond. */
internal enum class BinUnit { Day, Week, Month }

internal val GraphRange.binUnit: BinUnit
    get() = when (this) {
        GraphRange.WEEK, GraphRange.MONTH -> BinUnit.Day
        GraphRange.THREE_MONTHS -> BinUnit.Week
        GraphRange.YEAR, GraphRange.ALL -> BinUnit.Month
    }

// MARK: Days

/** Anki's day numbers (0 = today, -1 = yesterday) as dates, for chart axes. */
internal object StatDay {
    private val firstWeekday: DayOfWeek get() = WeekFields.of(Locale.getDefault()).firstDayOfWeek

    fun date(day: Int): LocalDate = LocalDate.now().plusDays(day.toLong())

    /** Days from today to [date]. */
    fun day(date: LocalDate): Int = ChronoUnit.DAYS.between(LocalDate.now(), date).toInt()

    /** The start of the bar a day falls in. */
    fun bin(day: Int, unit: BinUnit): LocalDate = start(date(day), unit)

    fun start(date: LocalDate, unit: BinUnit): LocalDate = when (unit) {
        BinUnit.Day -> date
        BinUnit.Week -> date.with(TemporalAdjusters.previousOrSame(firstWeekday))
        BinUnit.Month -> date.withDayOfMonth(1)
    }

    fun next(date: LocalDate, unit: BinUnit): LocalDate = when (unit) {
        BinUnit.Day -> date.plusDays(1)
        BinUnit.Week -> date.plusWeeks(1)
        BinUnit.Month -> date.plusMonths(1)
    }

    /** Every bar from the one [first] falls in to the one [last] falls in. */
    fun bins(first: Int, last: Int, unit: BinUnit): List<LocalDate> {
        val end = bin(last, unit)
        val result = mutableListOf<LocalDate>()
        var d = bin(first, unit)
        while (!d.isAfter(end)) {
            result += d
            d = next(d, unit)
        }
        return result
    }

    fun title(date: LocalDate, unit: BinUnit): String = when (unit) {
        BinUnit.Day -> when (day(date)) {
            0 -> "Today"
            -1 -> "Yesterday"
            1 -> "Tomorrow"
            else -> date.format(DateTimeFormatter.ofPattern("EEE d MMM"))
        }
        BinUnit.Week -> "Week of ${date.format(DateTimeFormatter.ofPattern("d MMM"))}"
        BinUnit.Month -> date.format(DateTimeFormatter.ofPattern("MMMM yyyy"))
    }

    /** A short axis label for a bar. */
    fun axisLabel(date: LocalDate, unit: BinUnit): String = when (unit) {
        BinUnit.Day, BinUnit.Week -> date.format(DateTimeFormatter.ofPattern("d MMM"))
        BinUnit.Month -> date.format(DateTimeFormatter.ofPattern("MMM"))
    }

    fun mediumDate(date: LocalDate): String = date.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
}

// MARK: Formatting

internal fun number(n: Long): String = NumberFormat.getIntegerInstance().format(n)
internal fun number(n: Int): String = number(n.toLong())

internal fun percent(value: Double?): String =
    value?.let { NumberFormat.getPercentInstance().apply { maximumFractionDigits = 0 }.format(it) } ?: "—"

internal fun movesText(n: Long): String = if (n == 1L) "1 move" else "${number(n)} moves"

internal fun answersText(n: Long): String = if (n == 1L) "1 answer" else "${number(n)} answers"

internal fun daysUnit(n: Long): String = if (n == 1L) "day" else "days"

/** "+3", "−2", "+0". */
internal fun signed(n: Long): String = if (n >= 0) "+${number(n)}" else "−${number(-n)}"

/** "8 min", "1 hr, 20 min", "40 sec". */
internal fun durationText(millis: Long): String {
    val secs = (millis / 1000.0).roundToLong()
    if (secs < 60) return "$secs sec"
    val minutes = (secs / 60.0).roundToLong()
    val hours = minutes / 60
    return when {
        hours == 0L -> "$minutes min"
        minutes % 60 == 0L -> "$hours hr"
        else -> "$hours hr, ${minutes % 60} min"
    }
}

// MARK: Review kinds

/** The kinds of answers, in the order of Anki's Reviews graph. */
internal enum class ReviewKind(val title: String) {
    Learn("Learning"), Relearn("Relearning"), Young("Young"), Mature("Mature"), Filtered("Ahead");

    val color: ThemeColor
        get() = when (this) {
            Learn -> ThemeColor.learning.lighter()
            Relearn -> ThemeColor.learning
            Young -> ThemeColor.learned.lighter()
            Mature -> ThemeColor.learned
            Filtered -> ThemeColor.ahead
        }

    fun value(c: ReviewCounts): Long = when (this) {
        Learn -> c.learn
        Relearn -> c.relearn
        Young -> c.young
        Mature -> c.mature
        Filtered -> c.filtered
    }
}

// MARK: Move groups

/** Anki's card-count groups, in the order of the studied bar. */
internal enum class MoveGroup(val title: String) {
    New("New"), Learning("Learning"), Relearning("Relearning"), Young("Young"), Mature("Mature"), Suspended("Suspended");

    val color: ThemeColor
        get() = when (this) {
            New -> ThemeColor.new
            Learning -> ThemeColor.learning.lighter()
            Relearning -> ThemeColor.learning
            Young -> ThemeColor.learned.lighter()
            Mature -> ThemeColor.learned
            Suspended -> ThemeColor.inactive
        }

    fun count(c: CardCounts): Long = when (this) {
        New -> c.new
        Learning -> c.learn
        Relearning -> c.relearn
        Young -> c.young
        Mature -> c.mature
        Suspended -> c.suspended
    }
}

/** The moves by group as one bar, like the library's studied bar. */
@Composable
internal fun MoveGroupsBar(counts: CardCounts) {
    val groups = MoveGroup.entries
    SegmentedBar(
        segments = groups.map { it.count(counts) to it.color },
        total = groups.sumOf { it.count(counts) },
        modifier = Modifier.clearAndSetSemantics {},
        height = 10.dp,
    )
}
