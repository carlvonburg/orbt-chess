package org.orbtchess.orbt.ui.tips

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.RichTooltip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TooltipAnchorPosition
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.window.PopupPositionProvider

/**
 * Counts [tip] as shown while it is on screen (TipKit's `MaxDisplayCount(1)`): once it has been
 * shown for a moment and goes (its rule no longer holds, a tap outside, the screen left), it is
 * done. A tip that flickers on for less than a second, while the screen's state settles, isn't
 * counted. Call it once per screen, for the tip it shows, wherever that tip is drawn.
 */
@Composable
fun CountShown(tip: Tip?) {
    val tips = LocalTips.current ?: return
    if (tip == null) return
    val shown = remember(tip) { longArrayOf(0L) }
    LaunchedEffect(tip) { shown[0] = System.currentTimeMillis() }
    DisposableEffect(tip) {
        onDispose {
            if (shown[0] != 0L && System.currentTimeMillis() - shown[0] >= 1_000) tips.invalidate(tip)
        }
    }
}

/**
 * A popover tip from what it explains (SwiftUI's `popoverTip`): Material's rich tooltip, kept
 * open (persistent) above [content] while [LocalPopoverTip] is one of [tips]. It explains, never
 * asks for a tap: like a popover, it takes the first tap outside it to close, which ends it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TipAnchor(vararg tips: Tip, content: @Composable () -> Unit) {
    val store = LocalTips.current
    val current = LocalPopoverTip.current?.takeIf { it in tips }
    if (store == null) {
        content()
        return
    }
    val state = rememberTooltipState(isPersistent = true)
    // The tip last shown: it stays the tooltip's content while the tooltip fades out after it
    // is done (it would otherwise go blank mid-animation).
    var shown by remember { mutableStateOf<Tip?>(null) }
    if (current != null && current != shown) shown = current
    // A persistent tooltip shows until it is dismissed; leaving the composition (the rule no
    // longer holds) cancels the show, which dismisses it.
    LaunchedEffect(current) { if (current != null) state.show() }
    val above = TooltipDefaults.rememberTooltipPositionProvider(TooltipAnchorPosition.Above, spacingBetweenTooltipAndAnchor = 8.dp)
    val margin = with(LocalDensity.current) { 16.dp.roundToPx() }
    val position = remember(above, margin) { InsetPositionProvider(above, margin) }
    TooltipBox(
        positionProvider = position,
        tooltip = {
            val tip = shown ?: return@TooltipBox
            RichTooltip(
                title = { Text(tip.title) },
                action = {
                    TextButton(onClick = { state.dismiss(); store.invalidate(tip) }, shapes = ButtonDefaults.shapes()) { Text("Got It") }
                },
                caretShape = TooltipDefaults.caretShape(),
            ) { Text(tipMessage(tip), inlineContent = tipIcon(tip)) }
        },
        state = state,
        onDismissRequest = {
            state.dismiss()
            shown?.let(store::invalidate)
        },
        // Shown by the rules, not by a long press on what it explains.
        enableUserInput = false,
        focusable = true,
        content = content,
    )
}

/**
 * [base]'s position kept [margin] from the window's sides, as Material's margins around content:
 * a tip over a badge at the screen's edge would otherwise touch it. Its caret, placed from this
 * position, still points at the anchor.
 */
private class InsetPositionProvider(private val base: PopupPositionProvider, private val margin: Int) : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset {
        val position = base.calculatePosition(anchorBounds, windowSize, layoutDirection, popupContentSize)
        val right = windowSize.width - popupContentSize.width - margin
        if (right < margin) return position
        return IntOffset(position.x.coerceIn(margin, right), position.y)
    }
}

/**
 * An inline tip (SwiftUI's `TipView`): a card with the tip's title and message and a close
 * button, where there is room for it (the panel beside the board, under Study's status).
 */
@Composable
fun TipCard(tip: Tip?, modifier: Modifier = Modifier) {
    val store = LocalTips.current ?: return
    AnimatedVisibility(tip != null, modifier) {
        val shown = tip ?: return@AnimatedVisibility
        OutlinedCard(Modifier.fillMaxWidth()) {
            Row(Modifier.padding(start = 16.dp, top = 12.dp, bottom = 16.dp, end = 4.dp)) {
                Column(Modifier.weight(1f).padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(shown.title, style = MaterialTheme.typography.titleSmall)
                    Text(
                        tipMessage(shown),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        inlineContent = tipIcon(shown),
                    )
                }
                IconButton(onClick = { store.invalidate(shown) }, shapes = IconButtonDefaults.shapes(), modifier = Modifier.align(Alignment.Top)) {
                    Icon(Icons.Filled.Close, contentDescription = "Close Tip")
                }
            }
        }
    }
}

private const val ICON_ID = "icon"

/** The message, with the symbol of the button it names in place of `{icon}`. */
private fun tipMessage(tip: Tip): AnnotatedString = buildAnnotatedString {
    val parts = tip.message.split("{icon}")
    parts.forEachIndexed { index, part ->
        if (index > 0) appendInlineContent(ICON_ID, tip.iconLabel.ifEmpty { " " })
        append(part)
    }
}

private fun tipIcon(tip: Tip): Map<String, InlineTextContent> {
    val icon = tip.icon ?: return emptyMap()
    return mapOf(
        ICON_ID to InlineTextContent(Placeholder(1.2.em, 1.2.em, PlaceholderVerticalAlign.TextCenter)) {
            Icon(icon, contentDescription = null, tint = LocalContentColor.current)
        },
    )
}
