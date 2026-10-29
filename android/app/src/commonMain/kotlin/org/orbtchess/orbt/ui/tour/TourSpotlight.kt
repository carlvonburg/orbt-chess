package org.orbtchess.orbt.ui.tour

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/**
 * The tour's spotlight over the whole window, bars included (`TourSpotlight.swift`): Material's
 * scrim over everything but the step's targets, which are cut out and outlined; the scrim takes
 * no touches, so the only way on is the control the coach mark points at, or Skip Tour. Shown
 * while a tour screen is ([TourScreen]) and the step's targets are on screen.
 */
@Composable
fun TourSpotlight(guide: TourGuide, modifier: Modifier = Modifier) {
    val step = guide.step
    var origin by remember { mutableStateOf(Rect.Zero) }
    val density = LocalDensity.current
    val inset = with(density) { 6.dp.toPx() }
    val holes = if (guide.screens > 0 && origin.width > 0f) {
        val frames = guide.frames
        step.targets.mapNotNull { frames[it] }
            .filter { it.width > 0f && it.height > 0f && it.overlaps(origin) }
            // Only the part on screen (rows can run on below it).
            .map { it.intersect(origin).translate(-origin.topLeft).inflate(inset) }
    } else {
        emptyList()
    }
    Box(modifier.fillMaxSize().onGloballyPositioned { origin = it.boundsInRoot() }) {
        AnimatedVisibility(holes.isNotEmpty(), enter = fadeIn(), exit = fadeOut()) {
            if (holes.isEmpty()) return@AnimatedVisibility
            Spotlight(step, holes)
        }
    }
}

@Composable
private fun Spotlight(step: TourGuide.Step, holes: List<Rect>) {
    val scrim = MaterialTheme.colorScheme.scrim.copy(alpha = 0.45f)
    val outline = MaterialTheme.colorScheme.primary
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width = with(density) { maxWidth.toPx() }
        val height = with(density) { maxHeight.toPx() }
        Canvas(Modifier.fillMaxSize()) {
            val shade = Path().apply {
                fillType = PathFillType.EvenOdd
                addRect(Rect(Offset.Zero, size))
                holes.forEach { addRoundRect(RoundRect(it, CornerRadius(radius(it, density.density)))) }
            }
            drawPath(shade, scrim)
            holes.forEach {
                drawRoundRect(
                    outline, it.topLeft, it.size, CornerRadius(radius(it, density.density)),
                    style = Stroke(2.dp.toPx()),
                )
            }
        }
        // Touches in the shade stop here; those in a hole reach the control under it.
        for (cell in shadeCells(width, height, holes)) {
            Box(
                Modifier
                    .offset { IntOffset(cell.left.roundToInt(), cell.top.roundToInt()) }
                    .size(with(density) { cell.width.toDp() }, with(density) { cell.height.toDp() })
                    .pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) awaitPointerEvent().changes.forEach { it.consume() }
                        }
                    },
            )
        }
        // Points at the first target (Save, not Analysis): on the side with more room.
        val target = holes.first()
        val below = target.center.y < height / 2
        Box(
            Modifier.fillMaxSize().padding(
                top = if (below) with(density) { target.bottom.toDp() } + 8.dp else 0.dp,
                bottom = if (below) 0.dp else with(density) { (height - target.top).toDp() } + 8.dp,
            ).padding(horizontal = 16.dp),
            contentAlignment = if (below) Alignment.TopCenter else Alignment.BottomCenter,
        ) {
            ElevatedCard(Modifier.widthIn(max = 480.dp).fillMaxWidth()) { TourCardContent(step) }
        }
    }
}

/** The step's title and instruction with Skip Tour (the spotlight's coach mark, Study's card). */
@Composable
private fun TourCardContent(step: TourGuide.Step) {
    Column(Modifier.padding(start = 16.dp, end = 8.dp, top = 16.dp, bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(step.title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(end = 8.dp))
        Text(
            step.message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(end = 8.dp),
        )
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) { SkipTourButton() }
    }
}

/**
 * The tour's card in Study (`TourStudyCard`): what to do, without blocking the board. Shown on
 * the sample while the tour is at its Study step.
 */
@Composable
fun TourStudyCard(modifier: Modifier = Modifier) {
    Card(modifier.fillMaxWidth()) { TourCardContent(TourGuide.Step.Studying) }
}

/**
 * Skip Tour, confirmed first (`SkipTourButton.swift`): the tour doesn't come back by itself, so
 * the dialog says where it is.
 */
@Composable
fun SkipTourButton(button: @Composable (onClick: () -> Unit) -> Unit = { TextButton(onClick = it) { Text("Skip Tour") } }) {
    val guide = LocalTourGuide.current
    var confirming by remember { mutableStateOf(false) }
    button { confirming = true }
    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text("Skip the Tour?") },
            text = { Text("You can take it again any time in Settings › Show Tour.") },
            confirmButton = {
                TextButton(onClick = {
                    confirming = false
                    guide?.skip()
                }) { Text("Skip Tour") }
            },
            dismissButton = { TextButton(onClick = { confirming = false }) { Text("Continue Tour") } },
        )
    }
}

/** Buttons (short holes) are capsules, as Material's buttons are; larger areas rounded rectangles. */
private fun radius(hole: Rect, density: Float): Float =
    if (hole.height < 90f * density) minOf(hole.width, hole.height) / 2 else 16f * density

/**
 * The shade as rectangles that leave the holes out: the window cut into a grid at every hole's
 * edges, without the cells inside a hole.
 */
private fun shadeCells(width: Float, height: Float, holes: List<Rect>): List<Rect> {
    fun cuts(edges: List<Float>, end: Float) = (listOf(0f, end) + edges.map { it.coerceIn(0f, end) }).distinct().sorted()
    val xs = cuts(holes.flatMap { listOf(it.left, it.right) }, width)
    val ys = cuts(holes.flatMap { listOf(it.top, it.bottom) }, height)
    val cells = mutableListOf<Rect>()
    for (j in 0 until ys.size - 1) {
        for (i in 0 until xs.size - 1) {
            val cell = Rect(xs[i], ys[j], xs[i + 1], ys[j + 1])
            if (cell.width <= 0f || cell.height <= 0f) continue
            if (holes.none { it.contains(cell.center) }) cells += cell
        }
    }
    return cells
}
