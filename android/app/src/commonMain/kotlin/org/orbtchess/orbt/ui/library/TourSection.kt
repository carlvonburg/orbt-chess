package org.orbtchess.orbt.ui.library

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import orbt.app.generated.resources.Res
import org.jetbrains.compose.resources.ExperimentalResourceApi
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireEntry
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.SetupMode
import org.orbtchess.orbt.ui.tour.SkipTourButton
import org.orbtchess.orbt.ui.tour.TourGuide

/** The sample in the library, if it is there. */
internal fun sampleEntry(app: AppModel): RepertoireEntry? = app.library.entries.firstOrNull { TourGuide.isSample(it.pgnFile) }

/** The tour, from Start Tour to its end: it takes Today's place in the library. */
internal fun tourRunning(app: AppModel): Boolean = app.tour.step != TourGuide.Step.Off && sampleEntry(app) != null

/**
 * Adds the sample and offers the tour on it (`startTour` in LibraryView.swift, Settings' Show
 * Tour): the sample is added again if it was deleted. Throws when the sample can't be added,
 * with the tour off again.
 */
@OptIn(ExperimentalResourceApi::class)
suspend fun startTour(app: AppModel) {
    // The tour first: the sample's row shows its first tip.
    app.tour.start()
    try {
        val bytes = Res.readBytes("files/sample.pgn")
        val sample = app.library.addSample { bytes }
        // Opened now, so its row and Today show its moves and gaps from the start.
        app.documents.open(sample)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        app.tour.skip()
        throw e
    }
}

/**
 * The tour in Today's place (`tourSection` in LibraryView.swift), laid out like Today's card:
 * what it is, how far it got, or, once the sample's gap is studied, the user's own repertoire;
 * its one main action first.
 *
 * @param wide across a wide dashboard, as Today's card: the text on the leading side, the actions
 *   on the trailing side.
 */
@Composable
internal fun TourSection(app: AppModel, navigate: (Destination) -> Unit, modifier: Modifier = Modifier, wide: Boolean = false) {
    val step = app.tour.step
    val yourTurn = step == TourGuide.Step.Studying || step == TourGuide.Step.Finish
    val (title, detail) = when {
        step == TourGuide.Step.Ready -> "Learn by Filling a Gap" to
            "Answer a common reply in a sample 1.e4 repertoire, then study it. About two minutes."
        yourTurn -> "Your Turn" to "Now build a repertoire for the opening you play. The sample stays here to try things on."
        else -> "Tour in Progress" to "Pick up where you left off in the sample."
    }
    // Open, so its row shows its moves and gaps (an unopened new sidecar has none yet).
    LaunchedEffect(Unit) { sampleEntry(app)?.let { app.documents.open(it) } }

    @Composable
    fun text() {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }

    @Composable
    fun actions() {
        if (yourTurn) {
            ActionButton("Create Your Repertoire", prominent = true, onClick = {
                // The tour's end: New Repertoire, for the user's own.
                app.tour.skip()
                navigate(Destination.Setup(SetupMode.New()))
            })
            ActionButton("Not Now", prominent = false, onClick = { app.tour.skip() })
        } else {
            ActionButton(if (step == TourGuide.Step.Ready) "Start Tour" else "Continue Tour", prominent = true, onClick = {
                // The sample's overview, or its Browse once the tour got there.
                val sample = sampleEntry(app) ?: return@ActionButton
                navigate(Destination.Overview(sample.id))
                if (step >= TourGuide.Step.BiggestGap) navigate(Destination.Builder(sample.id))
            })
            SkipTourButton { ActionButton("Skip Tour", prominent = false, onClick = it) }
        }
    }

    val spacing = Arrangement.spacedBy(8.dp)
    if (wide) {
        Row(modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = spacing) { text() }
            Column(Modifier.weight(1f), verticalArrangement = spacing) { actions() }
        }
    } else {
        Column(modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = spacing) {
            text()
            actions()
        }
    }
}
