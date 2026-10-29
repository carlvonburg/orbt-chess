package org.orbtchess.orbt.ui.statistics

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.Placeholder
import org.orbtchess.orbt.ui.StatisticsScope

/**
 * Statistics (`StatisticsView.swift`, Anki's graphs): summary, streak, reviews, moves,
 * upcoming, retention, time of day, recall, intervals, weakest moves; scope and range pickers.
 *
 * @param inline true beside an overview or Today (the extra pane on wide windows, or under the
 *   overview): no top app bar, the scope fixed. False for the Statistics tab on a phone.
 * @param navigate [Destination.Builder] (a weakest move, with its start node), [Destination.CardInfo].
 */
@Composable
fun StatisticsScreen(
    app: AppModel,
    scope: StatisticsScope,
    inline: Boolean,
    navigate: (Destination) -> Unit,
    modifier: Modifier = Modifier,
) {
    // STUB
    Placeholder("Statistics", onBack = null, modifier = modifier) {
        Text("Scope: $scope, inline: $inline")
    }
}
