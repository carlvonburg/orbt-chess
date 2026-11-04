package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.ExposedDropdownMenu
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemColors
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// Settings pages on a wide window, as Windows' Settings and the Mac's grouped forms lay them
// out: no wider than a page reads well, centered, each setting's control
// beside its title (a number field, a menu, a short slider) instead of under it or in a dialog,
// a phone's way. Only on the desktop ([controlsBesideTitles]): Android's settings keep their rows
// (the value under the title, a dialog to change it) at every width, a tablet's too. A page
// narrower than [WideForm] has no wide rows.

/** The narrowest page whose rows put their controls beside their titles. */
private val WideForm = 600.dp

/** Whether this platform's settings put each control beside its title when there is room: the desktop's. */
internal expect val controlsBesideTitles: Boolean

/** The widest a settings page grows. */
private val FormMaxWidth = 760.dp

/** Whether this settings page is wide: its rows' controls beside their titles ([FormColumn]). */
val LocalWideForm = compositionLocalOf { false }

/** A settings page's content: at most [FormMaxWidth], centered, wide ([LocalWideForm]) on the desktop when there is room. On a wide window the shell shows these pages as dialogs. */
@Composable
fun FormColumn(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    BoxWithConstraints(modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        CompositionLocalProvider(LocalWideForm provides (controlsBesideTitles && maxWidth >= WideForm)) {
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
        textStyle = tabularDigits(MaterialTheme.typography.bodyLarge),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = modifier.widthIn(min = 96.dp),
    )
}

/**
 * One of several options: Material's exposed dropdown menu (a read-only field showing the choice,
 * a menu of all), each with its [detail].
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun <T> ChoiceDropdown(
    options: List<T>,
    selected: T,
    onSelect: (T) -> Unit,
    title: (T) -> String,
    modifier: Modifier = Modifier,
    detail: ((T) -> String?)? = null,
) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded, { expanded = it }, modifier) {
        // The anchor's own click handling never opens the menu on the desktop when the box comes
        // after the screen's first frame (Compose Multiplatform material3 1.13.0-beta01, as
        // `RatingPicker`), so a click target over the field opens it; the anchor still places it.
        Box(Modifier.menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable, enabled = false)) {
            OutlinedTextField(
                value = title(selected),
                onValueChange = {},
                readOnly = true,
                singleLine = true,
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.matchParentSize().clickable(role = Role.DropdownList) { expanded = !expanded })
        }
        ExposedDropdownMenu(expanded, { expanded = false }) {
            options.forEachIndexed { index, option ->
                DropdownMenuItem(
                    text = { Text(title(option)) },
                    shape = MenuDefaults.itemShape(index, options.size).shape,
                    supportingText = detail?.invoke(option)?.let { { Text(it) } },
                    onClick = {
                        expanded = false
                        onSelect(option)
                    },
                )
            }
        }
    }
}

/** Whether this screen is shown as a dialog (a wide window's settings, [org.orbtchess.orbt.ui.components.PlatformDialog]). */
val LocalInDialog = compositionLocalOf { false }
