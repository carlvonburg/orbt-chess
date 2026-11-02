package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.BoxScope
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/**
 * Pull to refresh where there is a finger to pull: Material's `PullToRefreshBox` on Android; on
 * the desktop just the content (the library follows its folder there, and a mouse wheel at the
 * top pulls the indicator in with no fling to release it, so it would stay).
 */
@Composable
internal expect fun Refreshable(
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
)
