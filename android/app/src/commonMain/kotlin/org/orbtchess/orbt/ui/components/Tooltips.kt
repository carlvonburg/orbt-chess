package org.orbtchess.orbt.ui.components

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.Text
import androidx.compose.material3.TooltipAnchorPosition
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * An icon-only action with its name in a plain tooltip (Material 3: a plain tooltip labels an
 * icon button; it shows on long press, and on hover with a pointer). The name is also what
 * screen readers say. [above] for bottom bars, below for top bars.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TooltipIconButton(
    label: String,
    icon: ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    above: Boolean = false,
) {
    Tooltip(label, above) {
        IconButton(onClick = onClick, modifier = modifier, enabled = enabled) { Icon(icon, contentDescription = label) }
    }
}

/** [TooltipIconButton] for an on/off action (the engine); [filled]: Material's filled toggle, filled while on. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TooltipIconToggleButton(
    label: String,
    icon: ImageVector,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    above: Boolean = false,
    filled: Boolean = false,
) {
    Tooltip(label, above) {
        if (filled) {
            FilledIconToggleButton(checked = checked, onCheckedChange = onCheckedChange, modifier = modifier) {
                Icon(icon, contentDescription = label)
            }
        } else {
            IconToggleButton(checked = checked, onCheckedChange = onCheckedChange, modifier = modifier) {
                Icon(icon, contentDescription = label)
            }
        }
    }
}

/** Material's plain tooltip with [label] around [content]. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Tooltip(label: String, above: Boolean = false, content: @Composable () -> Unit) {
    TooltipBox(
        positionProvider = TooltipDefaults.rememberTooltipPositionProvider(
            if (above) TooltipAnchorPosition.Above else TooltipAnchorPosition.Below,
        ),
        tooltip = { PlainTooltip { Text(label) } },
        state = rememberTooltipState(),
        content = content,
    )
}
