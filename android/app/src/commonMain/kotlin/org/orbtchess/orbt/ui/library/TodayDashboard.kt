package org.orbtchess.orbt.ui.library

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.StatisticsScope
import org.orbtchess.orbt.ui.components.GroupedBackground
import org.orbtchess.orbt.ui.components.groupedTopAppBarColors
import org.orbtchess.orbt.ui.statistics.StatisticsDashboard
import org.orbtchess.orbt.ui.statistics.SurfaceCard

/**
 * Today on wide windows (the Today column in LibraryView.swift): the detail pane while the
 * library's Today row is selected. Today's card across the page (the tour's while it runs), then
 * every repertoire's statistics. On a phone Today is the library's first section instead.
 *
 * @param navigate [Destination.StudyAll], [Destination.Drill], [Destination.Builder], the tour's
 *   destinations, and the statistics' ([Destination.CardInfo]).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodayDashboard(app: AppModel, navigate: (Destination) -> Unit, modifier: Modifier = Modifier) {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        containerColor = GroupedBackground,
        topBar = {
            LargeFlexibleTopAppBar(title = { Text("Today") }, scrollBehavior = scrollBehavior, colors = groupedTopAppBarColors())
        },
    ) { padding ->
        StatisticsDashboard(app, StatisticsScope.All, navigate, Modifier.padding(padding)) { columns ->
            SurfaceCard {
                // While the tour runs, its card instead.
                val inset = Modifier.padding(vertical = 8.dp)
                val wide = columns > 1
                if (tourRunning(app)) TourSection(app, navigate, inset, wide) else TodayCard(app, navigate, inset, wide)
            }
        }
    }
}
