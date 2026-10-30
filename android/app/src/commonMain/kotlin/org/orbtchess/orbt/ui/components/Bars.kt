package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.BottomAppBarDefaults
import androidx.compose.material3.Surface
import androidx.compose.ui.unit.dp
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow

/**
 * The bottom bar of the board screens (Build, Study, Analysis): Material 3's docked toolbar
 * (which replaces the bottom app bar), its items spread evenly across it. Compose Material 3 1.4
 * keeps the docked toolbar (`FlexibleBottomAppBar`) internal, so this lays it out with its
 * tokens (`DockedToolbarTokens`): surface container, 64 dp high, 16 dp leading and trailing
 * space, over the navigation bar. Replace it with `FlexibleBottomAppBar` once that is public (1.5).
 * Icon-only items name themselves with a tooltip ([TooltipIconButton], `above = true`); the
 * screen's main action is a labelled button in it, in place of a FAB.
 */
@Composable
fun DockedToolbar(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    Surface(modifier, color = MaterialTheme.colorScheme.surfaceContainer) {
        Row(
            Modifier
                .windowInsetsPadding(BottomAppBarDefaults.windowInsets)
                .fillMaxWidth()
                .height(64.dp)
                .padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
            content = content,
        )
    }
}

/**
 * A top app bar's title with its subtitle under it, styled as Material 3's subtitle slot
 * (label medium, on-surface-variant). Compose Material 3 1.4 keeps `TopAppBar(title, subtitle)`
 * internal; replace this with that overload once it is public (1.5).
 */
@Composable
fun TitleWithSubtitle(title: String, subtitle: String?) {
    Column {
        Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (!subtitle.isNullOrEmpty()) {
            Text(
                subtitle,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
