package org.orbtchess.orbt.ui.statistics

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow

// Charts, drawn: Material has none (Swift Charts in the Swift app). One quiet style for all of
// them: thin outline-variant gridlines, small on-surface-variant labels, marks in the color of
// their meaning; tapping or dragging across a chart selects a bar, tapping it again clears it.

/** The axes' look, from the Material theme. */
private class ChartStyle(val grid: Color, val label: TextStyle, val rule: Color)

@Composable
private fun chartStyle() = ChartStyle(
    grid = MaterialTheme.colorScheme.outlineVariant,
    label = MaterialTheme.typography.labelSmall.copy(color = MaterialTheme.colorScheme.onSurfaceVariant),
    rule = MaterialTheme.colorScheme.onSurfaceVariant,
)

/** A round axis maximum at or above [value]: 1, 2, 2.5, 5 times a power of ten. */
internal fun niceMax(value: Double): Double {
    if (value <= 0) return 1.0
    val power = 10.0.pow(floor(log10(value)))
    val step = listOf(1.0, 2.0, 2.5, 5.0, 10.0).first { it * power >= value - 1e-9 }
    return step * power
}

/** A label to draw on an axis, at a value in the chart's units. */
internal class AxisLabel(val value: Double, val text: String)

/** The default value axis: zero, half and the top, in whole numbers. */
internal fun countAxis(top: Double, format: (Double) -> String = { number(it.toLong()) }): List<AxisLabel> =
    listOf(0.0, top / 2, top).filter { it == 0.0 || it == top || it == floor(it) }.map { AxisLabel(it, format(it)) }

/**
 * Stacked bars, one slot per bar ([bars]: each bar's parts bottom up, value and color), with a
 * value axis on the trailing side and labels under chosen bars ([xLabels], by index). With
 * [labelAtStart] a label marks the bar's leading edge (a boundary, as 70%), else its middle.
 * [overlay] draws over the bars (the hour chart's line), given the plot and the slot width.
 */
@Composable
internal fun BarChart(
    bars: List<List<Pair<Double, Color>>>,
    xLabels: Map<Int, String>,
    description: String,
    modifier: Modifier = Modifier,
    height: Dp = 160.dp,
    top: Double = niceMax(bars.maxOfOrNull { bar -> bar.sumOf { it.first } } ?: 0.0),
    axis: List<AxisLabel> = countAxis(top),
    leadingAxis: List<AxisLabel> = emptyList(),
    labelAtStart: Boolean = false,
    selected: Int? = null,
    onSelect: ((Int?) -> Unit)? = null,
    overlay: (DrawScope.(plot: Rect, slot: Float) -> Unit)? = null,
) {
    val style = chartStyle()
    val measurer = rememberTextMeasurer()
    val count = bars.size
    val layout = remember { GeometryHolder() }
    Canvas(
        modifier.fillMaxWidth().height(height)
            .semantics { contentDescription = description }
            .selecting(count, selected, onSelect, layout),
    ) {
        val geometry = plotGeometry(measurer, style, axis, leadingAxis, xLabels.isNotEmpty(), count)
        layout.value = geometry
        val plot = geometry.plot
        drawValueAxis(measurer, style, plot, top, axis, leading = false)
        drawValueAxis(measurer, style, plot, top, leadingAxis, leading = true)
        val slot = geometry.slot
        val gap = (slot * 0.2f).coerceAtMost(6.dp.toPx())
        for ((i, bar) in bars.withIndex()) {
            val dim = selected != null && selected != i
            var y = plot.bottom
            for ((value, color) in bar) {
                if (value <= 0) continue
                val h = (value / top * plot.height).toFloat()
                drawRect(
                    if (dim) color.copy(alpha = color.alpha * 0.4f) else color,
                    topLeft = Offset(plot.left + i * slot + gap / 2, y - h),
                    size = Size(slot - gap, h),
                )
                y -= h
            }
        }
        for ((i, text) in xLabels) {
            val measured = measurer.measure(text, style.label)
            val x = if (labelAtStart) plot.left + i * slot else plot.left + (i + 0.5f) * slot - measured.size.width / 2
            drawText(measured, topLeft = Offset(x.coerceIn(0f, size.width - measured.size.width), plot.bottom + 4.dp.toPx()))
        }
        overlay?.invoke(this, plot, slot)
    }
}

/**
 * Stacked areas over evenly spaced points ([points]: each point's values bottom up, in the
 * order of [colors]), a value axis on the trailing side, and a rule at the selected point.
 */
@Composable
internal fun AreaChart(
    points: List<List<Double>>,
    colors: List<Color>,
    xLabels: Map<Int, String>,
    description: String,
    modifier: Modifier = Modifier,
    height: Dp = 160.dp,
    selected: Int? = null,
    onSelect: ((Int?) -> Unit)? = null,
) {
    val style = chartStyle()
    val measurer = rememberTextMeasurer()
    val top = niceMax(points.maxOfOrNull { it.sum() } ?: 0.0)
    val axis = countAxis(top)
    val count = points.size
    val layout = remember { GeometryHolder() }
    Canvas(
        modifier.fillMaxWidth().height(height)
            .semantics { contentDescription = description }
            .selecting(count, selected, onSelect, layout),
    ) {
        val geometry = plotGeometry(measurer, style, axis, emptyList(), xLabels.isNotEmpty(), count)
        layout.value = geometry
        val plot = geometry.plot
        drawValueAxis(measurer, style, plot, top, axis, leading = false)
        if (count == 0) return@Canvas
        fun x(i: Int) = if (count == 1) plot.center.x else plot.left + i * plot.width / (count - 1)
        fun y(v: Double) = plot.bottom - (v / top * plot.height).toFloat()
        val below = DoubleArray(count)
        for ((layer, color) in colors.withIndex()) {
            val above = DoubleArray(count) { below[it] + (points[it].getOrNull(layer) ?: 0.0) }
            if ((0 until count).any { above[it] > below[it] }) {
                val path = Path().apply {
                    moveTo(x(0), y(above[0]))
                    for (i in 1 until count) lineTo(x(i), y(above[i]))
                    for (i in count - 1 downTo 0) lineTo(x(i), y(below[i]))
                    close()
                }
                drawPath(path, color)
            }
            above.copyInto(below)
        }
        selected?.let { i ->
            drawLine(style.rule, Offset(x(i), plot.top), Offset(x(i), plot.bottom), strokeWidth = 1.dp.toPx())
        }
        for ((i, text) in xLabels) {
            val measured = measurer.measure(text, style.label)
            val left = (x(i) - measured.size.width / 2).coerceIn(0f, size.width - measured.size.width)
            drawText(measured, topLeft = Offset(left, plot.bottom + 4.dp.toPx()))
        }
    }
}

/**
 * Anki's calendar: a square a day, weeks as columns and weekdays as rows ([cells]: week,
 * weekday, color), with labels under the weeks in [weekLabels]. Tapping a day selects it.
 */
@Composable
internal fun CalendarGrid(
    weeks: Int,
    cells: List<Triple<Int, Int, Color>>,
    weekLabels: Map<Int, String>,
    description: String,
    modifier: Modifier = Modifier,
    selected: Pair<Int, Int>? = null,
    onSelect: (Pair<Int, Int>?) -> Unit,
) {
    val style = chartStyle()
    val measurer = rememberTextMeasurer()
    val current by rememberUpdatedState(selected)
    val select by rememberUpdatedState(onSelect)
    BoxWithAspect(weeks, modifier) { cellSize, labelHeight ->
        Canvas(
            Modifier.fillMaxWidth().height(cellSize * 7 + labelHeight)
                .semantics { contentDescription = description }
                .pointerInput(weeks) {
                    detectTapGestures { o ->
                        val side = size.width.toFloat() / weeks
                        val cell = (o.x / side).toInt().coerceIn(0, weeks - 1) to (o.y / side).toInt()
                        select(if (cell.second > 6 || cell == current) null else cell)
                    }
                },
        ) {
            val side = size.width / weeks
            val inset = side * 0.08f
            for ((week, weekday, color) in cells) {
                val dim = selected != null && selected != (week to weekday)
                drawRoundRect(
                    if (dim) color.copy(alpha = color.alpha * 0.5f) else color,
                    topLeft = Offset(week * side + inset, weekday * side + inset),
                    size = Size(side - 2 * inset, side - 2 * inset),
                    cornerRadius = CornerRadius(2.dp.toPx()),
                )
            }
            for ((week, text) in weekLabels) {
                val measured = measurer.measure(text, style.label)
                val x = (week * side + inset).coerceAtMost(size.width - measured.size.width)
                drawText(measured, topLeft = Offset(x, 7 * side + 2.dp.toPx()))
            }
        }
    }
}

/** The calendar's size: square cells across the width, and a line for the month labels. */
@Composable
private fun BoxWithAspect(weeks: Int, modifier: Modifier, content: @Composable (Dp, Dp) -> Unit) {
    androidx.compose.foundation.layout.BoxWithConstraints(modifier.fillMaxWidth()) {
        content(maxWidth / weeks, 18.dp)
    }
}

/** A line through points (value 0…1 of the plot's height at each slot's middle) with dots. */
internal fun DrawScope.lineThrough(points: List<Pair<Int, Double>>, color: Color, plot: Rect, slot: Float) {
    if (points.isEmpty()) return
    fun at(p: Pair<Int, Double>) = Offset(plot.left + (p.first + 0.5f) * slot, plot.bottom - (p.second * plot.height).toFloat())
    val path = Path().apply {
        moveTo(at(points[0]).x, at(points[0]).y)
        for (p in points.drop(1)) lineTo(at(p).x, at(p).y)
    }
    drawPath(path, color, style = Stroke(width = 2.dp.toPx()))
    for (p in points) drawCircle(color, radius = 2.5.dp.toPx(), center = at(p))
}

// MARK: Layout

/** Where a chart's plot is, and how wide a bar's slot is. */
private class PlotGeometry(val plot: Rect, val slot: Float) {
    companion object {
        val Empty = PlotGeometry(Rect.Zero, 0f)
    }
}

/** The last drawn geometry, for the gestures (not state: drawing it must not recompose). */
private class GeometryHolder {
    var value = PlotGeometry.Empty
}

private fun DrawScope.plotGeometry(
    measurer: TextMeasurer,
    style: ChartStyle,
    axis: List<AxisLabel>,
    leadingAxis: List<AxisLabel>,
    hasXLabels: Boolean,
    count: Int,
): PlotGeometry {
    val pad = 6.dp.toPx()
    fun width(labels: List<AxisLabel>) =
        labels.maxOfOrNull { measurer.measure(it.text, style.label).size.width }?.let { it + pad } ?: 0f
    val labelHeight = measurer.measure("0", style.label).size.height
    val plot = Rect(
        left = width(leadingAxis),
        top = labelHeight / 2f,
        right = size.width - width(axis),
        bottom = size.height - if (hasXLabels) labelHeight + 4.dp.toPx() else labelHeight / 2f,
    )
    return PlotGeometry(plot, if (count > 0) plot.width / count else plot.width)
}

private fun DrawScope.drawValueAxis(
    measurer: TextMeasurer,
    style: ChartStyle,
    plot: Rect,
    top: Double,
    labels: List<AxisLabel>,
    leading: Boolean,
) {
    for (label in labels) {
        val y = plot.bottom - (label.value / top * plot.height).toFloat()
        if (!leading) drawLine(style.grid, Offset(plot.left, y), Offset(plot.right, y), strokeWidth = 1.dp.toPx())
        val measured = measurer.measure(label.text, style.label)
        val x = if (leading) plot.left - measured.size.width - 6.dp.toPx() else plot.right + 6.dp.toPx()
        drawText(measured, topLeft = Offset(max(0f, x), y - measured.size.height / 2))
    }
}

/** Tapping selects the slot under the finger (again: clears it); dragging moves the selection. */
private fun Modifier.selecting(
    count: Int,
    selected: Int?,
    onSelect: ((Int?) -> Unit)?,
    layout: GeometryHolder,
): Modifier {
    if (onSelect == null || count == 0) return this
    fun index(x: Float): Int {
        val g = layout.value
        if (g.slot <= 0f) return 0
        return floor((x - g.plot.left) / g.slot).toInt().coerceIn(0, count - 1)
    }
    return this
        .pointerInput(count, selected) {
            detectTapGestures { o ->
                val i = index(o.x)
                onSelect(if (i == selected) null else i)
            }
        }
        .pointerInput(count) {
            detectHorizontalDragGestures { change, _ -> onSelect(index(change.position.x)) }
        }
}
