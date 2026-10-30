package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FloatingToolbarDefaults
import androidx.compose.material3.HorizontalFloatingToolbar
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp

/**
 * A board screen's bar under the board on wide windows (the detail pane, as iPad's bar under the
 * board): Material 3 Expressive's floating toolbar, as wide as the board. In it, back and
 * forward, then the move list ([MoveList], `Modifier.weight(1f)`: it takes the width left and
 * scrolls sideways), then the screen's board actions, icon-only and named by tooltips shown
 * above. The screen's main action, when it has one now, is the toolbar's FAB ([BoardToolbarFab]):
 * Material's floating toolbar and FAB pairing. A phone keeps the docked toolbar (Material's
 * choice for compact widths).
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun BoardToolbar(
    modifier: Modifier = Modifier,
    mainAction: (@Composable () -> Unit)? = null,
    content: @Composable RowScope.() -> Unit,
) {
    // Material's toolbar and FAB pairing, side by side: the pairing's own layout
    // (`HorizontalFloatingToolbar(floatingActionButton = …)`) sizes the toolbar to its content and
    // can't stretch it to the board's width, so the FAB is placed beside it here, 8 dp apart and
    // centred, as the pairing places it, with the pairing's elevation.
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        HorizontalFloatingToolbar(
            expanded = true,
            modifier = Modifier.weight(1f),
            expandedShadowElevation = if (mainAction != null) {
                FloatingToolbarDefaults.ContainerExpandedElevationWithFab
            } else {
                FloatingToolbarDefaults.ContainerExpandedElevation
            },
            content = content,
        )
        if (mainAction != null) {
            Spacer(Modifier.width(8.dp))
            mainAction()
        }
    }
}

/** The floating toolbar's FAB: the screen's main action (Save, Next Line), named by its tooltip. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun BoardToolbarFab(label: String, icon: ImageVector, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Tooltip(label, above = true) {
        // The FAB fills what it is given (the pairing's layout sizes it): the pairing's 56 dp.
        FloatingToolbarDefaults.StandardFloatingActionButton(onClick = onClick, modifier = modifier.size(56.dp)) {
            Icon(icon, contentDescription = label)
        }
    }
}
