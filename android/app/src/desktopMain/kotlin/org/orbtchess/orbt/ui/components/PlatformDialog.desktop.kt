package org.orbtchess.orbt.ui.components

import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.decodeToImageBitmap
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.window.DialogModalityType
import androidx.compose.ui.window.DialogWindow
import androidx.compose.ui.window.rememberDialogState

/**
 * A window of its own, modal to the app's: the system's title bar (named by the content,
 * [LocalDialogWindowTitle]) and ✕, the app's icon, Esc closes it as the system's dialogs.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
actual fun PlatformDialog(
    onDismissRequest: () -> Unit,
    width: Dp,
    height: Dp,
    containerColor: Color,
    dismissOnClickOutside: Boolean,
    content: @Composable () -> Unit,
) {
    val title = remember { mutableStateOf("ORBT Chess") }
    val icon = remember {
        object {}.javaClass.getResourceAsStream("/orbt-icon.png")?.use { BitmapPainter(it.readBytes().decodeToImageBitmap()) }
    }
    DialogWindow(
        onCloseRequest = onDismissRequest,
        state = rememberDialogState(size = DpSize(width, height)),
        title = title.value,
        icon = icon,
        modalityType = DialogModalityType.DocumentModal,
        onPreviewKeyEvent = { event ->
            if (event.key == Key.Escape && event.type == KeyEventType.KeyDown) {
                onDismissRequest()
                true
            } else {
                false
            }
        },
    ) {
        CompositionLocalProvider(LocalDialogWindowTitle provides title) {
            Surface(color = containerColor, content = content)
        }
    }
}
