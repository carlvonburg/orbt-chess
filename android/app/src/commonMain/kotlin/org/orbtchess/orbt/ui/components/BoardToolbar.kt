package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.tappableElement
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FlexibleBottomAppBar
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.FloatingToolbarDefaults
import androidx.compose.material3.HorizontalFloatingToolbar
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
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
 * Under [FloatingToolbarScaffold] with 3-button navigation it is Material's docked toolbar
 * instead ([LocalDockedToolbar]): the same items in a bar along the bottom edge, over the
 * navigation bar's buttons.
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
    if (LocalDockedToolbar.current) {
        FlexibleBottomAppBar(
            modifier = modifier,
            horizontalArrangement = if (fill) Arrangement.Start else Arrangement.Center,
        ) {
            content()
            if (mainAction != null) {
                Spacer(Modifier.width(8.dp))
                mainAction()
            }
        }
        return
    }
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

/** True inside [FloatingToolbarScaffold]'s docked toolbar: [BoardToolbar] is then a docked bar. */
private val LocalDockedToolbar = staticCompositionLocalOf { false }

/**
 * Whether the system shows a navigation bar with buttons along the bottom edge (Android's
 * 3-button or 2-button navigation in portrait; gesture navigation has no tappable bar, and in
 * landscape the buttons are at the side).
 */
@Composable
private fun buttonNavigationBarAtBottom(): Boolean =
    WindowInsets.tappableElement.getBottom(LocalDensity.current) > 0

/**
 * A board screen on a phone: the top app bar, the content filling the rest of the screen and
 * scrolling under the floating [toolbar], which floats 16 dp above the bottom edge (as iPhone's
 * glass bar). [content] gets the padding to leave: the top app bar's at the top, and at the
 * bottom room for the toolbar, so the last row can be scrolled clear of it.
 *
 * Over a navigation bar with buttons (3-button navigation) a toolbar floating above another bar
 * looks out of place, so the toolbar is docked instead: Scaffold's bottom bar, Material's docked
 * toolbar, drawn behind the navigation bar's buttons, and the content ends above it.
 */
@Composable
fun FloatingToolbarScaffold(
    modifier: Modifier = Modifier,
    topBar: @Composable () -> Unit,
    toolbar: @Composable () -> Unit,
    snackbarHost: @Composable () -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    if (buttonNavigationBarAtBottom()) {
        Scaffold(
            modifier,
            topBar = topBar,
            bottomBar = { CompositionLocalProvider(LocalDockedToolbar provides true) { toolbar() } },
            snackbarHost = snackbarHost,
            content = content,
        )
        return
    }
    // The snackbar above the floating toolbar, as Material places it over a bottom bar.
    Scaffold(modifier, topBar = topBar, snackbarHost = {
        Box(Modifier.padding(bottom = BoardToolbarHeight + ToolbarOffset * 2)) { snackbarHost() }
    }) { padding ->
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
        if (LocalDockedToolbar.current) {
            // In the docked toolbar it sits in the bar, without its shadow (Material's FAB in a bottom app bar).
            FloatingActionButton(
                onClick = onClick,
                modifier = modifier.size(56.dp),
                elevation = FloatingActionButtonDefaults.bottomAppBarFabElevation(),
            ) {
                Icon(icon, contentDescription = label)
            }
            return@Tooltip
        }
        FloatingToolbarDefaults.StandardFloatingActionButton(onClick = onClick, modifier = modifier.size(56.dp)) {
            Icon(icon, contentDescription = label)
        }
    }
}
