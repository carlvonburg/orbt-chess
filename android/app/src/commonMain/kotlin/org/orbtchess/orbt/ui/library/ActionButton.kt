package org.orbtchess.orbt.ui.library

import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import org.orbtchess.orbt.ui.components.MenuBuilder
import org.orbtchess.orbt.ui.components.ExpressiveMenu
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.RowScope
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier

/**
 * A screen's action button (`actionButton(prominent:)` in Swift): all the same width, the most
 * likely one Material's filled button, the others its tonal one (emphasis by style, not size).
 * Material 3 Expressive's medium button (56 dp, its shapes, padding and type for that size): a
 * screen's main actions, not a row's.
 */
@Composable
fun ActionButton(text: String, prominent: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val height = ButtonDefaults.MediumContainerHeight
    val size = modifier.fillMaxWidth().heightIn(min = height)
    val padding = ButtonDefaults.contentPaddingFor(height)
    val label: @Composable RowScope.() -> Unit = { Text(text, style = ButtonDefaults.textStyleFor(height)) }
    if (prominent) {
        Button(onClick, modifier = size, shapes = ButtonDefaults.shapesFor(height), contentPadding = padding, content = label)
    } else {
        FilledTonalButton(onClick, modifier = size, shapes = ButtonDefaults.shapesFor(height), contentPadding = padding, content = label)
    }
}

/** An action button that opens a menu (SwiftUI's `Menu` styled as an action button). */
@Composable
fun ActionMenuButton(
    text: String,
    prominent: Boolean,
    modifier: Modifier = Modifier,
    items: MenuBuilder.() -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        ActionButton(text, prominent, onClick = { expanded = true })
        ExpressiveMenu(expanded, onDismissRequest = { expanded = false }, content = items)
    }
}
