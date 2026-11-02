package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemColors
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// Settings pages on a wide window, as Windows' Settings and the Mac's grouped forms lay them
// out: no wider than a page reads well, centered, each setting's control
// beside its title (a number field, a menu, a short slider) instead of under it or in a dialog,
// a phone's way. Phones keep theirs: a page narrower than [WideForm] has no wide rows.

/** The narrowest page whose rows put their controls beside their titles. */
private val WideForm = 600.dp

/** The widest a settings page grows. */
private val FormMaxWidth = 760.dp

/** Whether this settings page is wide: its rows' controls beside their titles ([FormColumn]). */
val LocalWideForm = compositionLocalOf { false }

/** A settings page's content: at most [FormMaxWidth], centered, wide ([LocalWideForm]) when there is room. On a wide window the shell shows these pages as dialogs. */
@Composable
fun FormColumn(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    BoxWithConstraints(modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        CompositionLocalProvider(LocalWideForm provides (maxWidth >= WideForm)) {
            Column(Modifier.widthIn(max = FormMaxWidth).fillMaxWidth(), content = content)
        }
    }
}

/** A setting on a wide page: its title (and [supporting] line) at the start, its [control] at the end, [controlWidth] wide. */
@Composable
fun WideRow(
    title: String,
    controlWidth: Dp,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    colors: ListItemColors = ListItemDefaults.colors(),
    control: @Composable (Modifier) -> Unit,
) {
    ListItem(
        modifier = modifier,
        supportingContent = supporting?.let { { Text(it) } },
        // A list item's trailing slot is set in its small label style: controls take the body's.
        trailingContent = { ProvideTextStyle(MaterialTheme.typography.bodyLarge) { control(Modifier.widthIn(max = controlWidth)) } },
        colors = colors,
    ) { Text(title) }
}

/** A whole number in [range], typed in place (Material has no stepper); each valid value is kept as typed. */
@Composable
fun NumberField(value: Int, range: IntRange, onChange: (Int) -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    // Keyed by the value, so a value set elsewhere shows.
    var text by remember(value, enabled) { mutableStateOf(value.toString()) }
    OutlinedTextField(
        value = text,
        onValueChange = { new ->
            text = new.filter(Char::isDigit).take(range.last.toString().length)
            text.toIntOrNull()?.takeIf { it in range }?.let(onChange)
        },
        enabled = enabled,
        singleLine = true,
        isError = text.toIntOrNull()?.let { it !in range } ?: true,
        // As round as the menus and buttons beside it.
        shape = RoundedCornerShape(percent = 50),
        textStyle = tabularDigits(MaterialTheme.typography.bodyLarge),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = modifier.widthIn(min = 96.dp),
    )
}

/** One of several options as a button showing the chosen one that opens a menu of all (a desktop's combo box), each with its [detail]. */
@Composable
fun <T> ChoiceMenuButton(
    options: List<T>,
    selected: T,
    onSelect: (T) -> Unit,
    title: (T) -> String,
    modifier: Modifier = Modifier,
    detail: ((T) -> String?)? = null,
) {
    var open by remember { mutableStateOf(false) }
    Box(modifier) {
        OutlinedButton(onClick = { open = true }, shapes = ButtonDefaults.shapes(), modifier = Modifier.fillMaxWidth()) {
            Text(title(selected), Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
        }
        ExpressiveMenu(open, onDismissRequest = { open = false }) {
            group {
                for (option in options) {
                    item(title(option), selected = option == selected, supporting = detail?.invoke(option)) { onSelect(option) }
                }
            }
        }
    }
}

/** Whether this screen is shown as a dialog (a wide window's settings): it closes with ✕, not back. */
val LocalInDialog = compositionLocalOf { false }
