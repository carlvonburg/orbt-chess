package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.dp

// A dialog with something to save, on a wide window, as a desktop's (Windows' content dialogs,
// the Mac's sheets, Material's basic dialogs): its buttons in a row at the bottom, Cancel and then
// the default action, filled, at the end; Esc cancels (back) and Enter takes the default action.
// Dialogs with nothing to save close with ✕ instead. Phones keep their sheets' and full-screen
// dialogs' own places for these buttons.

/** A dialog's buttons at its bottom: [leading] at the start (a wizard's Back), then Cancel and [confirm] at the end. */
@Composable
fun DialogButtons(
    confirm: String,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
    confirmEnabled: Boolean = true,
    leading: @Composable RowScope.() -> Unit = {},
) {
    Row(
        modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        leading()
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onCancel, shapes = ButtonDefaults.shapes()) { Text("Cancel") }
        Button(onClick = onConfirm, enabled = confirmEnabled, shapes = ButtonDefaults.shapes()) { Text(confirm) }
    }
}

/** Enter takes a dialog's default action when nothing focused in it takes the key (a multi-line field's new line). */
fun Modifier.defaultAction(enabled: Boolean, action: () -> Unit): Modifier = onKeyEvent { event ->
    val enter = event.key == Key.Enter || event.key == Key.NumPadEnter
    if (enabled && enter && event.type == KeyEventType.KeyDown) {
        action()
        true
    } else {
        false
    }
}
