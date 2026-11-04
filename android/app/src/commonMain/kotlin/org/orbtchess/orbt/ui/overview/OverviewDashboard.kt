package org.orbtchess.orbt.ui.overview

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.School
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.StatisticsScope
import org.orbtchess.orbt.ui.components.GroupedBackground
import org.orbtchess.orbt.ui.library.EntryStats
import org.orbtchess.orbt.ui.statistics.StatCard
import org.orbtchess.orbt.ui.statistics.StatisticsDashboard
import org.orbtchess.orbt.ui.theme.ThemeColor

/**
 * A repertoire's overview on wide windows (the detail pane beside the library): the overview's
 * Coverage and Study as two cards side by side, equal in height with their actions on one line
 * (stacked where only one column fits), then the repertoire's statistics. The same top app bar
 * and ⋮ menu as [OverviewScreen], whose Statistics row the statistics here replace.
 *
 * @param navigate [Destination.Builder], [Destination.Drill], [Destination.RepertoireSettings],
 *   [Destination.StudyOptions], and the statistics' ([Destination.CardInfo]).
 * @param onBack null where the overview is beside the library (nothing to go back to).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OverviewDashboard(
    app: AppModel,
    document: RepertoireDocument,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val id = document.entryId
    OverviewEffects(app, document)
    val stats = EntryStats.of(document)
    val scrollBehavior = TopAppBarDefaults.pinnedScrollBehavior()
    Scaffold(
        modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        containerColor = GroupedBackground,
        topBar = { OverviewTopBar(document, scrollBehavior, navigate, onBack) },
    ) { padding ->
        StatisticsDashboard(app, StatisticsScope.Repertoire(id), navigate, Modifier.padding(padding)) { columns ->
            val browse = { navigate(Destination.Builder(id)) }
            if (columns > 1) {
                // Side by side, stretched to the taller one, so their buttons line up.
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    CoverageCard(app, document, stats, browse, Modifier.weight(1f).fillMaxHeight())
                    StudyCard(document, stats, navigate, Modifier.weight(1f).fillMaxHeight())
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    CoverageCard(app, document, stats, browse)
                    StudyCard(document, stats, navigate)
                }
            }
        }
    }
}

/** The overview's Coverage section as a card: how complete, the gaps, saved moves, Browse / Edit. */
@Composable
private fun CoverageCard(app: AppModel, document: RepertoireDocument, stats: EntryStats, browse: () -> Unit, modifier: Modifier = Modifier) {
    StatCard("Coverage", Icons.Filled.AccountTree, modifier, color = ThemeColor.built) {
        CoverageSummary(app, document, stats, Modifier.fillMaxWidth())
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Saved moves", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
            SavedMovesCount(stats)
        }
        ActionAtBottom { BrowseButton(stats, browse) }
    }
}

/** The overview's Study section as a card: how far along, what is due today, Study Now. */
@Composable
private fun StudyCard(document: RepertoireDocument, stats: EntryStats, navigate: (Destination) -> Unit, modifier: Modifier = Modifier) {
    StatCard("Study", Icons.Filled.School, modifier) {
        if (stats.progress.cards == 0L) {
            // Nothing to count yet: only what to do.
            NothingToStudy(Modifier.fillMaxWidth())
            return@StatCard
        }
        StudyProgress(stats, Modifier.fillMaxWidth())
        StudyToday(document, stats, Modifier.fillMaxWidth())
        ActionAtBottom { StudyAction(document, stats, navigate) }
    }
}

/** A card's action, pinned to its bottom when the card is stretched to its neighbour's height. */
@Composable
private fun ColumnScope.ActionAtBottom(action: @Composable () -> Unit) {
    Spacer(Modifier.weight(1f))
    Column(Modifier.padding(top = 4.dp)) { action() }
}
