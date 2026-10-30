package org.orbtchess.orbt.ui.statistics

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridItemSpan
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.GraphRange
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.StatisticsScope
import org.orbtchess.orbt.ui.components.ChoiceButtonGroup
import org.orbtchess.orbt.ui.components.EmptyState
import org.orbtchess.orbt.ui.components.Symbols

/**
 * The library's detail pane on wide windows (Material's list-detail layout, the library the
 * list): one scrolling page of cards. First [lead], across the page (Today's card, or a
 * repertoire's Coverage and Study), then "Statistics" ("· All Repertoires" on Today) with its period and the
 * statistics' cards. Two columns where each gets [MinColumnWidth], else one; [lead] is told how
 * many, to lay its cards side by side or stacked. The period is this page's own.
 *
 * @param navigate for the statistics' cards: [Destination.Builder] (a weakest move), [Destination.CardInfo].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StatisticsDashboard(
    app: AppModel,
    scope: StatisticsScope,
    navigate: (Destination) -> Unit,
    modifier: Modifier = Modifier,
    lead: @Composable (columns: Int) -> Unit,
) {
    val model = rememberStatistics(app, scope)
    val graphs = model.graphs
    val hasData = model.hasData()
    val coroutines = rememberCoroutineScope()
    val refreshState = rememberPullToRefreshState()
    PullToRefreshBox(
        isRefreshing = model.isLoading && graphs != null,
        state = refreshState,
        indicator = {
            PullToRefreshDefaults.LoadingIndicator(refreshState, model.isLoading && graphs != null, Modifier.align(Alignment.TopCenter))
        },
        onRefresh = { coroutines.launch { model.load(app, scope) } },
        modifier = modifier.fillMaxSize(),
    ) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val columns = dashboardColumns(maxWidth - Gutter * 2)
            LazyVerticalStaggeredGrid(
                columns = StaggeredGridCells.Fixed(columns),
                contentPadding = PaddingValues(Gutter),
                horizontalArrangement = Arrangement.spacedBy(Gutter),
                verticalItemSpacing = Gutter,
                modifier = Modifier.fillMaxSize(),
            ) {
                item("lead", span = StaggeredGridItemSpan.FullLine) { lead(columns) }
                item("statisticsHeader", span = StaggeredGridItemSpan.FullLine) {
                    // A repertoire's page already has its name as its title (and selected in the
                    // list): its section is just "Statistics". Today's names what it covers.
                    val title = if (scope is StatisticsScope.Repertoire) "Statistics" else "Statistics · ${scopeTitle(app, scope)}"
                    StatisticsHeader(title, model.range) { model.range = it }
                }
                when {
                    graphs == null && model.isLoading -> item("loading", span = StaggeredGridItemSpan.FullLine) {
                        LoadingIndicator(Modifier.fillMaxWidth().padding(24.dp))
                    }
                    graphs == null || !hasData -> item("empty", span = StaggeredGridItemSpan.FullLine) {
                        EmptyState(
                            "No Statistics Yet",
                            Symbols.statistics,
                            description = "Study a repertoire to see your progress here.",
                        )
                    }
                    else -> statisticsCards(graphs, model, navigate)
                }
            }
        }
    }
}

/** A card column needs this much; two columns at most (iPad's dashboard). */
private val MinColumnWidth = 320.dp

/** The page's margins and the space between cards. */
private val Gutter = 16.dp

/** Two columns where both fit [MinColumnWidth], else one. */
private fun dashboardColumns(width: Dp): Int = if (width >= MinColumnWidth * 2 + Gutter) 2 else 1

/** The section's title and the period (a connected button group), wrapping when narrow. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StatisticsHeader(title: String, range: GraphRange, choose: (GraphRange) -> Unit) {
    FlowRow(
        Modifier.fillMaxWidth().padding(top = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalArrangement = Arrangement.spacedBy(8.dp),
        itemVerticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(end = 16.dp).semantics { heading() },
        )
        ChoiceButtonGroup(GraphRange.entries, range, choose, label = { it.shortTitle }, fill = false)
    }
}
