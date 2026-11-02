package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.AlertDialogDefaults
import androidx.compose.material3.BasicAlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties

/** Material's dialog with content of its own (`BasicAlertDialog`), in Material's dialog shape and elevation. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
actual fun PlatformDialog(
    onDismissRequest: () -> Unit,
    width: Dp,
    height: Dp,
    containerColor: Color,
    dismissOnClickOutside: Boolean,
    content: @Composable () -> Unit,
) {
    BasicAlertDialog(
        onDismissRequest = onDismissRequest,
        // As wide as the content asks, up to [width]: a basic dialog's 560 dp is a phone's.
        properties = DialogProperties(dismissOnClickOutside = dismissOnClickOutside, usePlatformDefaultWidth = false),
    ) {
        Surface(
            // Material's margin around a dialog on a large screen.
            Modifier.padding(24.dp).widthIn(max = width).heightIn(max = height).fillMaxSize(),
            shape = AlertDialogDefaults.shape,
            color = containerColor,
            tonalElevation = AlertDialogDefaults.TonalElevation,
            content = content,
        )
    }
}
