package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CornerBasedShape
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarColors
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

// Material 3 Expressive's grouped lists (Android 16's Settings): a page in the surface container
// color, its rows in groups of segments in the surface color, the group's ends rounded large and
// the segments between rounded extra small, 2 dp apart (Material's segmented list items:
// `ListItemDefaults.segmentedShapes`, `SegmentedGap`, `segmentedColors`). The group takes any
// rows (list items, a text field, a chart), so screens keep their rows and get the segments.

/** The background of a grouped page (Material's color for a page of segmented lists). */
val GroupedBackground: Color
    @Composable @ReadOnlyComposable
    get() = MaterialTheme.colorScheme.surfaceContainer

/** A grouped page's top app bar: on the page's color, scrolled or not, as Android 16's Settings. */
@Composable
fun groupedTopAppBarColors(): TopAppBarColors = TopAppBarDefaults.topAppBarColors(
    containerColor = GroupedBackground,
    scrolledContainerColor = GroupedBackground,
)

/**
 * A titled group of rows (a settings section): its title in the primary color, the rows as one
 * [SegmentedGroup], and a line of explanation under it.
 */
@Composable
fun ListSection(
    title: String?,
    modifier: Modifier = Modifier,
    footer: String? = null,
    content: @Composable () -> Unit,
) {
    Column(modifier.fillMaxWidth().padding(bottom = 12.dp)) {
        if (title != null) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(start = 32.dp, end = 32.dp, top = 12.dp, bottom = 8.dp).semantics { heading() },
            )
        }
        SegmentedGroup(Modifier.padding(horizontal = 16.dp), content = content)
        if (footer != null) {
            Text(
                footer,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp),
            )
        }
    }
}

/**
 * Rows as Material's segmented list: each child (a row) on a segment in [color], the first and
 * last rounded `shapes.large` on the outside, `shapes.extraSmall` between, 2 dp apart; each row is
 * clipped to its segment, so a row's ripple and selection follow it. Rows that draw their own
 * container (a `ListItem`, in the surface color) and rows that draw none (a text field, a column
 * of text) look alike.
 */
@Composable
fun SegmentedGroup(
    modifier: Modifier = Modifier,
    color: Color = MaterialTheme.colorScheme.surface,
    content: @Composable () -> Unit,
) {
    val outer = MaterialTheme.shapes.large
    val inner = MaterialTheme.shapes.extraSmall
    // The segments' places, written by the layout and read when drawing (the same frame).
    val segments = remember { SegmentPlaces() }
    Layout(
        content = content,
        modifier = modifier.drawWithContent {
            for (i in 0 until segments.count) {
                val outline = segmentShape(i, segments.count, outer, inner)
                    .createOutline(Size(size.width, segments.heights[i].toFloat()), layoutDirection, this)
                translate(top = segments.tops[i].toFloat()) { drawOutline(outline, color) }
            }
            drawContent()
        },
    ) { measurables, constraints ->
        val gap = ListItemDefaults.SegmentedGap.roundToPx()
        val child = constraints.copy(minHeight = 0)
        val placeables = measurables.map { it.measure(child) }.filter { it.height > 0 }
        val width = if (constraints.hasBoundedWidth) constraints.maxWidth else placeables.maxOfOrNull { it.width } ?: 0
        val height = placeables.sumOf { it.height } + gap * (placeables.size - 1).coerceAtLeast(0)
        segments.update(placeables.map { it.height }, gap)
        layout(width, height.coerceAtLeast(constraints.minHeight)) {
            var y = 0
            placeables.forEachIndexed { index, placeable ->
                val shape = segmentShape(index, placeables.size, outer, inner)
                placeable.placeWithLayer(0, y) {
                    this.shape = shape
                    clip = true
                }
                y += placeable.height + gap
            }
        }
    }
}

/** The shape of segment [index] of [count]: large outside, extra small between. */
private fun segmentShape(index: Int, count: Int, outer: CornerBasedShape, inner: CornerBasedShape): CornerBasedShape = when {
    count == 1 -> outer
    index == 0 -> outer.copy(bottomStart = inner.bottomStart, bottomEnd = inner.bottomEnd)
    index == count - 1 -> outer.copy(topStart = inner.topStart, topEnd = inner.topEnd)
    else -> inner
}

private class SegmentPlaces {
    var count = 0
    var tops = IntArray(0)
    var heights = IntArray(0)

    fun update(sizes: List<Int>, gap: Int) {
        count = sizes.size
        heights = sizes.toIntArray()
        tops = IntArray(count)
        var y = 0
        for (i in 0 until count) {
            tops[i] = y
            y += sizes[i] + gap
        }
    }
}
