package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FloatingToolbarDefaults
import androidx.compose.material3.HorizontalFloatingToolbar
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp

/**
 * A board screen's bottom bar (iPhone's bottom bar, iPad's bar under the board): Material 3
 * Expressive's floating toolbar, on phones as on tablets. Icon-only items named by tooltips shown
 * above, back and forward kept together first. Beside the board (the detail pane) it is as wide
 * as the board, with the move list ([MoveList], `Modifier.weight(1f)`: it takes the width left
 * and scrolls sideways) after back and forward; on a phone it spans the screen and a
 * `Spacer(Modifier.weight(1f))` parts the groups, as iPhone's flexible spacer. The screen's main
 * action, when it has one now, is the toolbar's FAB ([BoardToolbarFab]): Material's floating
 * toolbar and FAB pairing.
 *
 * @param fill as wide as it is allowed (with weighted content); false: as wide as its items,
 *   centred by its container (Analysis on a phone: back and forward only).
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun BoardToolbar(
    modifier: Modifier = Modifier,
    mainAction: (@Composable () -> Unit)? = null,
    fill: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    // Material's toolbar and FAB pairing, side by side: the pairing's own layout
    // (`HorizontalFloatingToolbar(floatingActionButton = …)`) sizes the toolbar to its content and
    // can't stretch it to the board's width, so the FAB is placed beside it here, 8 dp apart and
    // centred, as the pairing places it, with the pairing's elevation.
    Row(if (fill) modifier.fillMaxWidth() else modifier, verticalAlignment = Alignment.CenterVertically) {
        HorizontalFloatingToolbar(
            expanded = true,
            modifier = if (fill) Modifier.weight(1f) else Modifier,
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

/** The floating toolbar's height (Material's container size); its FAB is smaller. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
val BoardToolbarHeight = FloatingToolbarDefaults.ContainerSize

/** Material's distance from the toolbar to the screen's bottom edge, and to the content above. */
private val ToolbarOffset = 16.dp

/**
 * A board screen on a phone: the top app bar, the content filling the rest of the screen and
 * scrolling under the floating [toolbar], which floats 16 dp above the bottom edge (as iPhone's
 * glass bar). [content] gets the padding to leave: the top app bar's at the top, and at the
 * bottom room for the toolbar, so the last row can be scrolled clear of it.
 */
@Composable
fun FloatingToolbarScaffold(
    modifier: Modifier = Modifier,
    topBar: @Composable () -> Unit,
    toolbar: @Composable () -> Unit,
    content: @Composable (PaddingValues) -> Unit,
) {
    Scaffold(modifier, topBar = topBar) { padding ->
        val bottom = padding.calculateBottomPadding()
        Box(Modifier.fillMaxSize()) {
            content(
                PaddingValues(
                    top = padding.calculateTopPadding(),
                    bottom = bottom + BoardToolbarHeight + ToolbarOffset * 2,
                ),
            )
            Box(
                Modifier.align(Alignment.BottomCenter)
                    .padding(start = ToolbarOffset, end = ToolbarOffset, bottom = bottom + ToolbarOffset),
            ) { toolbar() }
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
