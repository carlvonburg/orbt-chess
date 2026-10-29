package org.orbtchess.orbt.ui.library

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier

/**
 * A screen's action button (`actionButton(prominent:)` in Swift): all the same width, the most
 * likely one Material's filled button, the others its tonal one (emphasis by style, not size).
 */
@Composable
fun ActionButton(text: String, prominent: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    if (prominent) {
        Button(onClick, modifier.fillMaxWidth()) { Text(text) }
    } else {
        FilledTonalButton(onClick, modifier.fillMaxWidth()) { Text(text) }
    }
}

/** An action button that opens a menu (SwiftUI's `Menu` styled as an action button). */
@Composable
fun ActionMenuButton(
    text: String,
    prominent: Boolean,
    modifier: Modifier = Modifier,
    items: @Composable ColumnScope.(close: () -> Unit) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        ActionButton(text, prominent, onClick = { expanded = true })
        DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
            items { expanded = false }
        }
    }
}
