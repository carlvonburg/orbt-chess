package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Surface
import androidx.compose.material3.rememberBottomSheetState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.navigationevent.NavigationEventInfo
import androidx.navigationevent.compose.NavigationBackHandler
import androidx.navigationevent.compose.rememberNavigationEventState

/** Whether the window is wide (the shell shows panes side by side): sheets and full-window screens are dialogs. */
val LocalWideWindow = compositionLocalOf { false }

/**
 * Where a wide window's sheet dialogs are drawn: over the whole window, from its root
 * ([SheetHost.Dialogs]), wherever the sheet is opened. Not Compose's `Dialog`, whose dimming and
 * clicks on the desktop are those of the pane it was opened from (Compose Multiplatform 1.13).
 */
@Stable
class SheetHost {
    private val dialogs = mutableStateListOf<@Composable () -> Unit>()

    internal fun show(dialog: @Composable () -> Unit) { dialogs += dialog }

    internal fun hide(dialog: @Composable () -> Unit) { dialogs -= dialog }

    /** The open sheet dialogs, the last opened on top; at the window's root, after its content. */
    @Composable
    fun Dialogs() {
        for (dialog in dialogs) dialog()
    }
}

/** The window's [SheetHost], provided by the shell. */
val LocalSheetHost = staticCompositionLocalOf<SheetHost?> { null }

/**
 * A sheet of its own content: Material's modal bottom sheet on a phone, a dialog on a wide window
 * ([LocalWideWindow]), where a sheet rising from the bottom edge of a large window is a phone's
 * way. The dialog is centered on the dimmed window, at most 640 by 880 dp, and closes with Esc
 * (back) or a click outside, as the sheet does with a swipe or a tap outside.
 * [expandedOnly]: the sheet opens fully, never half way (long lists, a search).
 * [closeButton]: the dialog has ✕ at its top end; false for a sheet with its own Cancel and Save
 * ([DialogButtons] at its bottom on a wide window).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdaptiveSheet(
    onDismissRequest: () -> Unit,
    containerColor: Color = BottomSheetDefaults.ContainerColor,
    expandedOnly: Boolean = false,
    closeButton: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val host = LocalSheetHost.current
    if (LocalWideWindow.current && host != null) {
        val dismiss by rememberUpdatedState(onDismissRequest)
        val latest by rememberUpdatedState(content)
        val close by rememberUpdatedState(closeButton)
        val dialog: @Composable () -> Unit = remember {
            { SheetDialog(onDismiss = { dismiss() }, containerColor, close) { latest() } }
        }
        DisposableEffect(host) {
            host.show(dialog)
            onDispose { host.hide(dialog) }
        }
    } else {
        val state = if (expandedOnly) {
            rememberBottomSheetState(SheetValue.Hidden, enabledValues = setOf(SheetValue.Hidden, SheetValue.Expanded))
        } else {
            rememberModalBottomSheetState()
        }
        ModalBottomSheet(onDismissRequest = onDismissRequest, sheetState = state, containerColor = containerColor, content = content)
    }
}

/** A sheet as a dialog over the dimmed window, as the shell's dialogs; back (Esc) closes it. */
@Composable
private fun SheetDialog(onDismiss: () -> Unit, containerColor: Color, closeButton: Boolean, content: @Composable ColumnScope.() -> Unit) {
    NavigationBackHandler(rememberNavigationEventState(NavigationEventInfo.None), onBackCompleted = onDismiss)
    Box(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.scrim.copy(alpha = 0.32f))
            .clickable(interactionSource = null, indication = null, onClick = onDismiss),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            Modifier.padding(32.dp).widthIn(max = 640.dp).heightIn(max = 880.dp).fillMaxWidth()
                // Clicks inside stay inside.
                .clickable(interactionSource = null, indication = null) {},
            shape = MaterialTheme.shapes.extraLarge,
            color = containerColor,
            shadowElevation = 6.dp,
        ) {
            Box {
                // The room a sheet's drag handle takes above its title.
                Column(Modifier.padding(top = 16.dp, bottom = 8.dp), content = content)
                if (closeButton) {
                    IconButton(onClick = onDismiss, shapes = IconButtonDefaults.shapes(), modifier = Modifier.align(Alignment.TopEnd).padding(4.dp)) {
                        Icon(Icons.Filled.Close, contentDescription = "Close")
                    }
                }
            }
        }
    }
}
