package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * A dialog as the platform has them: on the desktop a window of its own (Compose's
 * `DialogWindow`: the system's title bar, ✕ and Esc, modal to the app's window), on Android a
 * dialog window (Material's `BasicAlertDialog`). At most [width] by [height], in [containerColor].
 * [dismissOnClickOutside]: Android's tap outside closes it (not for a form with Save).
 */
@Composable
expect fun PlatformDialog(
    onDismissRequest: () -> Unit,
    width: Dp,
    height: Dp,
    containerColor: Color,
    dismissOnClickOutside: Boolean,
    content: @Composable () -> Unit,
)

/**
 * The title of the dialog window this content is in, where dialogs are windows with the system's
 * title bar (the desktop): the content names the dialog there instead of drawing a title. Null on
 * Android, whose dialogs draw their title.
 */
val LocalDialogWindowTitle = staticCompositionLocalOf<MutableState<String>?> { null }

/**
 * A sheet's or dialog's title and its [actions]: drawn as a heading, or, in a desktop dialog
 * window, the window's title (only the actions drawn).
 */
@Composable
fun SheetHeading(title: String, modifier: Modifier = Modifier, actions: @Composable RowScope.() -> Unit = {}) {
    val window = LocalDialogWindowTitle.current
    if (window != null) {
        SideEffect { window.value = title }
        Row(modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.End, content = actions)
        return
    }
    Row(modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(
            title,
            Modifier.weight(1f).semantics { heading() },
            style = MaterialTheme.typography.titleLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        actions()
    }
}
