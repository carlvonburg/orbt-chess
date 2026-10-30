package org.orbtchess.orbt.ui.statistics

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.staggeredgrid.LazyStaggeredGridScope
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridItemSpan
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.FilterAlt
import androidx.compose.material.icons.outlined.FilterAlt
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.orbtchess.orbt.ui.components.ChoiceButtonGroup
import org.orbtchess.orbt.ui.components.TooltipIconButton
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.GraphRange
import org.orbtchess.orbt.core.Graphs
import org.orbtchess.orbt.core.WeakMove
import org.orbtchess.orbt.core.total
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.StatisticsScope
import org.orbtchess.orbt.ui.components.EmptyState
import org.orbtchess.orbt.ui.components.Symbols

/**
 * Statistics (`StatisticsView.swift`, Anki's graphs): one screen of cards over one period,
 * each answering one question with the chart that suits it: how far the repertoire is learned
 * (moves), what is coming (upcoming), how much you study (reviews), how much you remember
 * (retention, by opening or repertoire), whether you keep at it (streak), when you study best
 * (time of day), how sure you are now (recall), intervals and the moves to work on.
 *
 * @param inline true beside an overview or Today (the extra pane on wide windows, or under the
 *   overview): no top app bar, the scope fixed. False for the Statistics tab on a phone, whose
 *   app bar has the repertoire filter.
 * @param navigate [Destination.Builder] (a weakest move, with its start node), [Destination.CardInfo].
 * @param onScopeChange the tab's filter chose another scope (the shell keeps it, as Swift's
 *   `AppModel.statisticsScope`); null keeps the choice in this screen.
 * @param paneTitle inline in a pane of its own (the extra pane): a top app bar titled Statistics.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StatisticsScreen(
    app: AppModel,
    scope: StatisticsScope,
    inline: Boolean,
    navigate: (Destination) -> Unit,
    modifier: Modifier = Modifier,
    onScopeChange: ((StatisticsScope) -> Unit)? = null,
    paneTitle: Boolean = false,
) {
    val model = remember { StatisticsModel() }
    // The tab's filter starts at the scope it was given; inline, the scope is the shell's.
    var localId by rememberSaveable(scope) { mutableStateOf((scope as? StatisticsScope.Repertoire)?.entryId) }
    val chosenId = if (onScopeChange != null) (scope as? StatisticsScope.Repertoire)?.entryId else localId
    val choose: (String?) -> Unit = { id ->
        if (onScopeChange != null) onScopeChange(id?.let { StatisticsScope.Repertoire(it) } ?: StatisticsScope.All) else localId = id
    }
    val current = if (inline) scope else chosenId?.let { StatisticsScope.Repertoire(it) } ?: StatisticsScope.All
    LaunchedEffect(current, app.library.entries.size) { model.load(app, current) }

    if (inline && paneTitle) {
        // A pane of its own beside the overview or Today: titled, as the Swift board column is.
        val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
        Scaffold(
            modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
            topBar = { LargeFlexibleTopAppBar(title = { Text("Statistics") }, scrollBehavior = scrollBehavior) },
        ) { padding ->
            StatisticsSummary(app, model, current, navigate, Modifier.padding(padding))
        }
        return
    }
    if (inline) {
        StatisticsSummary(app, model, current, navigate, modifier)
        return
    }
    // iOS's large title: the large flexible app bar, collapsing as the cards scroll.
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            LargeFlexibleTopAppBar(
                title = { Text("Statistics") },
                subtitle = { Text(scopeTitle(app, current)) },
                actions = { FilterMenu(app, chosenId, choose) },
                scrollBehavior = scrollBehavior,
            )
        },
    ) { padding ->
        StatisticsSummary(app, model, current, navigate, Modifier.padding(padding))
    }
}

private fun scopeTitle(app: AppModel, scope: StatisticsScope): String = when (scope) {
    StatisticsScope.All -> "All Repertoires"
    is StatisticsScope.Repertoire -> app.library.entry(scope.entryId)?.name ?: "Repertoire"
}

/** The repertoire filter, in the app bar; the icon is filled while filtering. */
@Composable
private fun FilterMenu(app: AppModel, chosenId: String?, choose: (String?) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        TooltipIconButton("Filter", if (chosenId == null) Icons.Outlined.FilterAlt else Icons.Filled.FilterAlt, { expanded = true })
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            val options = listOf<Pair<String?, String>>(null to "All Repertoires") +
                app.library.entries.filter { !it.needsSetup }.map { it.id to it.name }
            for ((id, name) in options) {
                DropdownMenuItem(
                    text = { Text(name) },
                    onClick = {
                        choose(id)
                        expanded = false
                    },
                    trailingIcon = { if (id == chosenId) Icon(Icons.Filled.Check, contentDescription = "Selected") },
                )
            }
        }
    }
}

/** The period, then the cards: one column on a phone, as many as fit on wider windows. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StatisticsSummary(
    app: AppModel,
    model: StatisticsModel,
    scope: StatisticsScope,
    navigate: (Destination) -> Unit,
    modifier: Modifier = Modifier,
) {
    val graphs = model.graphs
    val coroutines = rememberCoroutineScope()
    val refreshState = rememberPullToRefreshState()
    val hasData = remember(graphs) {
        graphs != null && (graphs.cardCounts().total > 0 || graphs.reviewsSummary(GraphRange.ALL).answers > 0)
    }
    when {
        graphs == null && model.isLoading -> Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            LoadingIndicator()
        }
        graphs == null || !hasData -> EmptyState(
            "No Statistics Yet",
            Symbols.statistics,
            modifier,
            description = "Study a repertoire to see your progress here.",
        )
        else -> PullToRefreshBox(
            isRefreshing = model.isLoading,
            state = refreshState,
            indicator = {
                PullToRefreshDefaults.LoadingIndicator(refreshState, model.isLoading, Modifier.align(Alignment.TopCenter))
            },
            onRefresh = { coroutines.launch { model.load(app, scope) } },
            modifier = modifier.fillMaxSize(),
        ) {
            LazyVerticalStaggeredGrid(
                columns = StaggeredGridCells.Adaptive(320.dp),
                contentPadding = PaddingValues(16.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalItemSpacing = 16.dp,
                modifier = Modifier.fillMaxSize(),
            ) {
                item(span = StaggeredGridItemSpan.FullLine) {
                    RangePicker(model.range) { model.range = it }
                }
                cards(graphs, model) { move ->
                    val document = model.document ?: return@cards
                    val node = model.node(move.epd) ?: return@cards
                    navigate(Destination.Builder(document.entryId, start = node))
                }
            }
        }
    }
}

/** Health's period picker: Material 3 Expressive's connected button group. */
@Composable
private fun RangePicker(range: GraphRange, choose: (GraphRange) -> Unit) {
    ChoiceButtonGroup(GraphRange.entries, range, choose, label = { it.shortTitle })
}

/**
 * The cards, in the Swift app's order: what a new user can read from the first day comes
 * first: how far the repertoire is learned, what comes next, how much is studied and remembered.
 */
private fun LazyStaggeredGridScope.cards(
    graphs: Graphs,
    model: StatisticsModel,
    open: (WeakMove) -> Unit,
) {
    item("moves") { MovesCard(graphs, model.range) }
    item("upcoming") { UpcomingCard(graphs, model.range) }
    item("reviews") { ReviewsCard(graphs, model.range) }
    item("retention") { RetentionCard(graphs) }
    if (model.document != null) {
        item("byOpening") {
            val rows = remember(graphs) { model.retentionByBranch() }
            if (rows.isNotEmpty()) {
                RetentionRowsCard(
                    "Retention by Opening", RetentionIcons.branches, rows,
                    "All time, for each reply to your first move: the share of reviews after a day or more answered correctly, and how many.",
                )
            }
        }
    } else if (model.repertoireRetention.isNotEmpty()) {
        item("byRepertoire") {
            RetentionRowsCard(
                "Retention by Repertoire", RetentionIcons.repertoires, model.repertoireRetention,
                "All time, for each repertoire: the share of reviews after a day or more answered correctly, and how many.",
            )
        }
    }
    item("streak") { StreakCard(graphs) }
    item("timeOfDay") { TimeOfDayCard(graphs, model.range) }
    item("recall") { RecallCard(graphs, model.range, remember(graphs) { model.expectedRecall }) }
    item("intervals") { IntervalsCard(graphs) }
    if (model.document != null) item("weakest") { WeakestMovesCard(model, open) }
}
