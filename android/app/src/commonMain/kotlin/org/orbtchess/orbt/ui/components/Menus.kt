package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.DropdownMenuGroup
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.DropdownMenuPopup
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SelectableDropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.isSecondaryPressed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.round
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color

/**
 * A menu as Material 3 Expressive draws one: Material's `DropdownMenuPopup` with its items in
 * `DropdownMenuGroup`s, the groups apart by Material's gap, each group and item with the shape
 * of its place (`MenuDefaults.groupShape`, `itemShape`), selected items (a choice) with
 * Material's selected shape and color. Material has the parts, not the assembly by index; this
 * only counts. Put it in the same `Box` as the button that opens it, as `DropdownMenu`.
 *
 * ```
 * ExpressiveMenu(open, { open = false }) {
 *     group { item("Undo", Symbols.undo, enabled = canUndo) { undo() } }
 *     group {
 *         item("Outline", Symbols.outline) { … }
 *         item("Delete", Symbols.delete, destructive = true) { … }
 *     }
 * }
 * ```
 *
 * Choosing an item closes the menu, then runs its action. A context menu opened by a right click
 * ([onSecondaryClick]) opens [at] the pointer, from the `Box`'s top start; without it, below
 * the anchor.
 */
@Composable
fun ExpressiveMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    at: IntOffset? = null,
    content: MenuBuilder.() -> Unit,
) {
    if (at != null) {
        // An empty anchor where the pointer was: the menu opens below and after it.
        Box(Modifier.offset { at }) { ExpressiveMenu(expanded, onDismissRequest, null, content) }
        return
    }
    val groups = MenuBuilder().apply(content).groups.filter { it.entries.isNotEmpty() }
    DropdownMenuPopup(expanded = expanded, onDismissRequest = onDismissRequest) {
        groups.forEachIndexed { groupIndex, group ->
            if (groupIndex > 0) Spacer(Modifier.height(MenuDefaults.GroupSpacing))
            DropdownMenuGroup(shapes = MenuDefaults.groupShape(groupIndex, groups.size)) {
                val items = group.entries.filterIsInstance<MenuEntry.Item>()
                var index = 0
                for (entry in group.entries) {
                    when (entry) {
                        is MenuEntry.Label -> MenuDefaults.DropdownMenuGroupLabel { Text(entry.text) }
                        is MenuEntry.Item -> {
                            val shapes = MenuDefaults.itemShape(index++, items.size)
                            val tint = if (entry.destructive) ThemeColor.failure.color else null
                            val choose = {
                                onDismissRequest()
                                entry.onClick()
                            }
                            val icon: (@Composable () -> Unit)? = entry.icon?.let { icon ->
                                { Icon(icon, contentDescription = null, tint = tint ?: LocalContentColor.current) }
                            }
                            val text: @Composable () -> Unit = {
                                Text(entry.text, color = tint ?: Color.Unspecified)
                            }
                            val supporting: (@Composable () -> Unit)? = entry.supporting?.let { { Text(it) } }
                            if (entry.selected != null) {
                                SelectableDropdownMenuItem(
                                    selected = entry.selected,
                                    onClick = choose,
                                    text = text,
                                    shapes = shapes,
                                    leadingIcon = icon,
                                    selectedLeadingIcon = { Icon(Icons.Filled.Check, contentDescription = "Selected") },
                                    supportingText = supporting,
                                    enabled = entry.enabled,
                                    // The selected choice in the secondary container, as the
                                    // app's selected rows: Material's menus select with the
                                    // tertiary, which the app leaves unused (Design/COLORS.md).
                                    colors = MenuDefaults.selectableItemColors(
                                        selectedContainerColor = MaterialTheme.colorScheme.secondaryContainer,
                                        selectedTextColor = MaterialTheme.colorScheme.onSecondaryContainer,
                                        selectedLeadingIconColor = MaterialTheme.colorScheme.onSecondaryContainer,
                                        selectedTrailingContentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                                    ),
                                )
                            } else {
                                DropdownMenuItem(
                                    onClick = choose,
                                    text = text,
                                    shape = shapes.shape,
                                    leadingIcon = icon,
                                    supportingText = supporting,
                                    enabled = entry.enabled,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/** The groups of an [ExpressiveMenu]. */
class MenuBuilder internal constructor() {
    internal val groups = mutableListOf<MenuGroupBuilder>()

    /** A group of items, apart from the others by Material's gap. */
    fun group(content: MenuGroupBuilder.() -> Unit) {
        groups += MenuGroupBuilder().apply(content)
    }
}

/** The items of one group. */
class MenuGroupBuilder internal constructor() {
    internal val entries = mutableListOf<MenuEntry>()

    /**
     * An item. [destructive]: Material's error color (Delete). [selected]: one of a choice, drawn
     * with Material's selected shape and a check while selected (null: an action).
     */
    fun item(
        text: String,
        icon: ImageVector? = null,
        enabled: Boolean = true,
        destructive: Boolean = false,
        selected: Boolean? = null,
        supporting: String? = null,
        onClick: () -> Unit,
    ) {
        entries += MenuEntry.Item(text, icon, enabled, destructive, selected, supporting, onClick)
    }

    /** The group's label (Material's group label), above its items. */
    fun label(text: String) {
        entries += MenuEntry.Label(text)
    }
}

internal sealed interface MenuEntry {
    class Item(
        val text: String,
        val icon: ImageVector?,
        val enabled: Boolean,
        val destructive: Boolean,
        val selected: Boolean?,
        val supporting: String?,
        val onClick: () -> Unit,
    ) : MenuEntry

    class Label(val text: String) : MenuEntry
}

/**
 * A right click (the mouse's secondary button), which opens an element's context menu on the
 * desktop as a long press does on a touch screen; [onClick] gets where, for [ExpressiveMenu]'s
 * `at` (in a `Box` with the element at its top start). Taken before the element's own click.
 */
fun Modifier.onSecondaryClick(onClick: ((IntOffset) -> Unit)?): Modifier =
    if (onClick == null) this else pointerInput(onClick) {
        awaitEachGesture {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            if (event.type == PointerEventType.Press && event.buttons.isSecondaryPressed) {
                val change = event.changes.first()
                change.consume()
                onClick(change.position.round())
            }
        }
    }
