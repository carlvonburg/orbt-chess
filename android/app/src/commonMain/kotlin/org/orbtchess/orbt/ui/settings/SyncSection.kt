package org.orbtchess.orbt.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CloudDone
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.SyncProblem
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.SyncState
import org.orbtchess.orbt.sync.SyncProvider
import org.orbtchess.orbt.sync.SyncService
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Sync (Android only; the Apple app has iCloud Drive): the repertoire folder synced with
 * Dropbox or Google Drive, chosen in a dialog and confirmed, with its status, Sync Now, and
 * signing in again when the provider asks.
 */
@Composable
internal fun SyncSection(app: AppModel) {
    val sync = app.sync
    val scope = rememberCoroutineScope()
    var choosing by remember { mutableStateOf(false) }
    // The choice waiting for the user's confirmation; null in it means none.
    var confirming by remember { mutableStateOf<Choice?>(null) }
    val provider = sync.provider
    Section(
        "Sync",
        footer = "Keeps your repertoires and training progress in the ORBT Chess folder of Dropbox or Google Drive, " +
            "and the same on your other devices. ORBT Chess sees only that folder.",
    ) {
        ValueRow("Sync with", provider?.let { p -> sync.account?.let { "${p.title} ($it)" } ?: p.title } ?: "Off") {
            choosing = true
        }
        if (provider != null) {
            val status = status(sync)
            ListItem(
                supportingContent = { Text(status.text, color = status.role?.color ?: MaterialTheme.colorScheme.onSurfaceVariant) },
                leadingContent = { Icon(status.icon, contentDescription = null, tint = status.role?.color ?: MaterialTheme.colorScheme.onSurfaceVariant) },
            ) { Text("Status") }
            if (sync.needsSignIn) {
                ListItem(
                    onClick = { scope.launch { sync.signIn(provider) } },
                    enabled = !sync.isSigningIn,
                    leadingContent = { Icon(Symbols.signIn, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
                ) { Text("Sign In to ${provider.title}", color = MaterialTheme.colorScheme.primary) }
            } else {
                ListItem(
                    onClick = { sync.syncNow() },
                    leadingContent = { Icon(Icons.Outlined.Sync, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
                ) { Text("Sync Now", color = MaterialTheme.colorScheme.primary) }
            }
        }
        sync.lastError?.let { error ->
            Text(
                error,
                style = MaterialTheme.typography.bodySmall,
                color = ThemeColor.failure.color,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
    }
    if (choosing) {
        ChoiceDialog(
            title = "Sync with",
            options = listOf(Choice(null)) + sync.auth.providers.map(::Choice),
            selected = Choice(provider),
            onDismiss = { choosing = false },
            onSelect = { if (it.provider != provider) confirming = it },
        ) { choice ->
            Text(choice.provider?.title ?: "Off (this device only)", style = MaterialTheme.typography.bodyLarge)
        }
    }
    confirming?.let { choice ->
        SwitchProviderDialog(
            from = provider,
            to = choice.provider,
            onDismiss = { confirming = null },
            onConfirm = {
                confirming = null
                scope.launch {
                    when (val to = choice.provider) {
                        null -> sync.signOut()
                        else -> sync.signIn(to)
                    }
                }
            },
        )
    }
}

/** A row of the choice: a provider, or none. */
private data class Choice(val provider: SyncProvider?)

/** What happens to the files, before signing in or stopping. */
@Composable
private fun SwitchProviderDialog(from: SyncProvider?, to: SyncProvider?, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (to == null) "Stop Syncing?" else "Sync with ${to.title}?") },
        text = {
            Column {
                if (to == null) {
                    Text(
                        "Your repertoires stay on this device, and in ${from?.title} as they are now. " +
                            "Changes are no longer synced.",
                    )
                } else {
                    Text(
                        "Your repertoires on this device are uploaded to the ORBT Chess folder in ${to.title}, " +
                            "and merged with those already there. Nothing is deleted.",
                    )
                    if (from != null) {
                        Text(
                            "Syncing with ${from.title} stops; your files there stay.",
                            modifier = Modifier.padding(top = 8.dp),
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm) { Text(if (to == null) "Stop Syncing" else "Sign In") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

private class Status(val text: String, val icon: ImageVector, val role: ThemeColor? = null)

/** The core's state in words; anything that asks the user to act is colored. */
private fun status(sync: SyncService): Status {
    fun time(ms: Long) = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault())
        .format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT))
    val waiting = sync.unsynced.size
    val pending = when (waiting) {
        0 -> ""
        1 -> " 1 file not uploaded yet."
        else -> " $waiting files not uploaded yet."
    }
    return when {
        sync.isSigningIn -> Status("Signing in…", Icons.Outlined.Sync)
        sync.needsSignIn -> Status("Sign in again to keep syncing.$pending", Icons.Outlined.SyncProblem, ThemeColor.todo)
        else -> when (val state = sync.state) {
            SyncState.Syncing -> Status("Syncing…$pending", Icons.Outlined.Sync)
            SyncState.NeedsToken -> Status("Signing in…", Icons.Outlined.Sync)
            is SyncState.Offline -> Status("Offline. Trying again at ${time(state.until)}.$pending", Icons.Outlined.CloudOff)
            is SyncState.Paused -> Status("Waiting for the provider until ${time(state.until)}.$pending", Icons.Outlined.CloudOff)
            else -> if (waiting == 0) Status("Up to date", Icons.Outlined.CloudDone)
            else Status("Waiting to upload.$pending", Icons.Outlined.CloudUpload)
        }
    }
}
