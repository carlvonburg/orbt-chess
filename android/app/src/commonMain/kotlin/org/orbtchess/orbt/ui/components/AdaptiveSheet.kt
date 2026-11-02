package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetValue
import androidx.compose.material3.rememberBottomSheetState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/** Whether the window is wide (the shell shows panes side by side): sheets and full-window screens are dialogs. */
val LocalWideWindow = compositionLocalOf { false }

/**
 * A sheet of its own content: Material's modal bottom sheet on a phone, the platform's dialog on
 * a wide window ([LocalWideWindow], [PlatformDialog]: a sheet rising from the bottom edge of a
 * large window is a phone's way). Its title is a [SheetHeading], the dialog window's title on the
 * desktop. [expandedOnly]: the sheet opens fully, never half way (long lists, a search).
 * [closeButton]: an Android dialog has Close at its bottom (a desktop dialog window has the
 * system's ✕); false for a sheet with its own Cancel and Save ([DialogButtons]).
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
    if (LocalWideWindow.current) {
        PlatformDialog(onDismissRequest, width = 640.dp, height = 800.dp, containerColor, dismissOnClickOutside = closeButton) {
            Column(Modifier.padding(top = 16.dp)) {
                // The sheet's content scrolls (or sizes itself) above the dialog's buttons.
                Column(Modifier.weight(1f, fill = false), content = content)
                if (closeButton && LocalDialogWindowTitle.current == null) DialogCloseButton(onDismissRequest)
            }
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
