package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

// A dialog on a wide window ([PlatformDialog]), as the platform's: on the desktop a window whose
// title bar names it and closes it (✕, Esc), on Android Material's dialog with its headline and
// its buttons at the bottom. A dialog with something to save has Cancel and then the default
// action, filled, at its bottom end, and Enter takes the default action; one with nothing to save
// has Close there on Android. Phones keep their sheets' and full-screen dialogs' own places for these.

/**
 * A dialog's title ([subtitle]: the step of a wizard): the window's title on the desktop, Material's
 * dialog headline on Android; a [back] arrow when the dialog has gone a page in.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DialogTitleBar(title: String, subtitle: String? = null, back: (() -> Unit)? = null) {
    val backButton: @Composable () -> Unit = {
        back?.let {
            IconButton(onClick = it, shapes = IconButtonDefaults.shapes()) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
        }
    }
    val window = LocalDialogWindowTitle.current
    if (window != null) {
        SideEffect { window.value = subtitle?.let { "$title — $it" } ?: title }
        if (back != null) TopAppBar(title = {}, navigationIcon = backButton, colors = groupedTopAppBarColors())
        return
    }
    Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, top = 24.dp, bottom = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        backButton()
        Column(Modifier.semantics { heading() }) {
            Text(title, style = MaterialTheme.typography.headlineSmall)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}

/** An Android dialog's Close at its bottom end, for a dialog with nothing to save. */
@Composable
fun DialogCloseButton(onClose: () -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp), horizontalArrangement = Arrangement.End) {
        TextButton(onClick = onClose, shapes = ButtonDefaults.shapes()) { Text("Close") }
    }
}

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
