package org.orbtchess.orbt.ui.onboarding

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.AlertDialog
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.draw.scale
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.SyncState
import org.orbtchess.orbt.core.boardSquare
import org.orbtchess.orbt.core.positionFromFen
import org.orbtchess.orbt.sync.SyncProvider
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.SetupMode
import org.orbtchess.orbt.ui.board.Board
import org.orbtchess.orbt.ui.board.BoardArrow
import org.orbtchess.orbt.ui.components.ExpressiveMenu
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.library.ActionButton
import org.orbtchess.orbt.ui.library.rememberPgnImport
import org.orbtchess.orbt.ui.components.StatusBadge
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color

/**
 * The whole window while there is no repertoire, in place of the tabs and the library, which
 * have nothing to show yet (`OnboardingView.swift`): one welcome screen, what the app does above
 * and the ways in at the bottom, in reach: a new repertoire (the likely one, prominent), a PGN,
 * or the repertoires already kept in Dropbox or Google Drive. The first repertoire, made here or
 * synced, ends it (the shell shows the library then).
 *
 * Brief, with nothing to set up first (the setup's defaults do), the rest taught in place by
 * tips ([org.orbtchess.orbt.ui.tips.Tips]). The app shows itself as on the store: a product shot
 * of its own board and cards (a gap, a correct answer, today's moves) on a glow of the app color.
 *
 * @param navigate [Destination.Setup].
 */
@Composable
fun OnboardingScreen(app: AppModel, navigate: (Destination) -> Unit, modifier: Modifier = Modifier) {
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val importPgn = rememberPgnImport(
        onPicked = { navigate(Destination.Setup(SetupMode.Importing(it.data, it.name))) },
        onError = { errorMessage = it },
    )
    val primary = MaterialTheme.colorScheme.primary
    val newRepertoire = { navigate(Destination.Setup(SetupMode.New)) }
    Surface(modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            // A wide, short window (a tablet or a phone in landscape, the desktop): the shot beside
            // the text and the ways in, as a store's landscape screenshot; else one column.
            val width = maxWidth
            val height = maxHeight
            val sideBySide = width > height && width >= 600.dp
            // The glow of the app color behind the shot, from the top edge; the backdrop, so it
            // stays put while the rest scrolls at large text sizes.
            Box(
                Modifier.fillMaxWidth().height(520.dp).drawBehind {
                    drawRect(
                        Brush.radialGradient(
                            listOf(primary.copy(alpha = 0.45f), Color.Transparent),
                            center = Offset(if (sideBySide) size.width / 4 else size.width / 2, 0f),
                            radius = 460.dp.toPx(),
                        ),
                    )
                },
            )
            if (sideBySide) {
                Row(Modifier.fillMaxSize().safeDrawingPadding(), verticalAlignment = Alignment.CenterVertically) {
                    BoxWithConstraints(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) {
                        // Larger beside the text on a big screen, where it has half the window to itself.
                        ProductShot(fit(maxWidth - 32.dp, maxHeight - 32.dp, largest = 1.4f))
                    }
                    Column(
                        Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(vertical = 24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
                    ) {
                        Headline()
                        Actions(app, newRepertoire, importPgn, Modifier)
                    }
                }
            } else {
                Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                    // Centered in the room above the buttons when it fits (a tall tablet), not at its top.
                    BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                        Column(
                            Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                                .heightIn(min = maxHeight).padding(vertical = 24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(28.dp, Alignment.CenterVertically),
                        ) {
                            // Smaller where the window is narrow or short, so the headline stays in
                            // view; larger on a big screen.
                            ProductShot(fit(width - 16.dp, height - 460.dp, largest = 1.4f))
                            Headline()
                        }
                    }
                    Actions(app, newRepertoire, importPgn, Modifier.align(Alignment.CenterHorizontally))
                }
            }
        }
    }

    errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            confirmButton = { TextButton(onClick = { errorMessage = null }, shapes = ButtonDefaults.shapes()) { Text("OK") } },
            title = { Text("Something went wrong") },
            text = { Text(message) },
        )
    }
}

/** The app's name, its headline and what it does. */
@Composable
private fun Headline() {
    Column(
        Modifier.widthIn(max = 480.dp).padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            "ORBT CHESS",
            style = MaterialTheme.typography.labelLarge.copy(letterSpacing = 1.5.sp, fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.primary,
        )
        Text(
            "Your Openings,\nWithout the Gaps",
            style = MaterialTheme.typography.displaySmall.copy(fontWeight = FontWeight.Bold),
            textAlign = TextAlign.Center,
        )
        Text(
            "Build from what opponents really play. Remember it with spaced repetition.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 2.dp),
        )
    }
}

/** The product shot's scale to fit [width] × [height]: at most [largest], and never below 55%. */
private fun fit(width: Dp, height: Dp, largest: Float = 1f): Float =
    minOf(largest, width / ShotWidth, height / ShotHeight).coerceAtLeast(0.55f)

private val ShotWidth = 380.dp
private val ShotHeight = 350.dp

/**
 * The ways in, stacked as welcome screens do: the likely one prominent, the other the same size,
 * and the sync as a menu of its providers under them.
 */
@Composable
private fun Actions(app: AppModel, newRepertoire: () -> Unit, importPgn: () -> Unit, modifier: Modifier) {
    Column(
        modifier.widthIn(max = 480.dp).fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ActionButton("New Repertoire", prominent = true, onClick = newRepertoire)
        ActionButton("Import a PGN…", prominent = false, onClick = importPgn)
        if (app.sync.auth.providers.isNotEmpty()) SyncChoice(app)
    }
}

/**
 * The choice Settings › Sync makes, checked on the one in use: a provider signs in (its
 * repertoires then arrive, and the first ends onboarding), or this device only. Nothing to
 * confirm: there are no repertoires to move. While signing in and downloading, what happens.
 */
@Composable
private fun SyncChoice(app: AppModel) {
    val sync = app.sync
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    val provider = sync.provider
    val status: String? = when {
        sync.isSigningIn -> "Signing in…"
        provider != null && sync.state == SyncState.Syncing -> "Downloading your repertoires from ${provider.title}…"
        else -> null
    }
    // A failed sign-in, or a provider with nothing yet: what is made now syncs there.
    val note: String? = sync.lastError ?: provider?.takeIf { sync.state == SyncState.Idle }
        ?.let { "${it.title} has no repertoires yet. The ones you create are kept there." }
    if (status != null) {
        Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            LoadingIndicator(Modifier.size(24.dp))
            Text(status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    } else if (note != null) {
        Text(
            note,
            style = MaterialTheme.typography.bodySmall,
            color = if (sync.lastError != null) ThemeColor.failure.color else MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
    if (sync.isSigningIn) return
    fun choose(to: SyncProvider?) {
        if (to == provider) return
        scope.launch {
            if (provider != null) sync.signOut()
            if (to != null) sync.signIn(to)
        }
    }
    Box {
        TextButton(onClick = { open = true }, shapes = ButtonDefaults.shapes()) {
            Text("Sync: ${provider?.title ?: "Off"}")
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
        }
        ExpressiveMenu(open, onDismissRequest = { open = false }) {
            group {
                label("Sync with")
                for (choice in sync.auth.providers) item(choice.title, selected = provider == choice) { choose(choice) }
                item("Off", selected = provider == null, supporting = "This device only") { choose(null) }
            }
        }
    }
}

/**
 * The app on show, as on the store: the Najdorf as Build draws it for Black (White's most played
 * reply, solid; one not prepared yet, dashed), tilted, with cards from the app floating around
 * it: that reply as a gap, a correct answer in Study, today's moves. Fixed example numbers, so
 * it looks the same offline on the first launch. A fixed layout, scaled to fit the window.
 */
@Composable
private fun ProductShot(scale: Float) {
    // Laid out at its own size and drawn scaled, in a box of the scaled size.
    Box(Modifier.size(ShotWidth * scale, ShotHeight * scale), contentAlignment = Alignment.Center) {
        ShotContent(Modifier.requiredSize(ShotWidth, ShotHeight).scale(scale))
    }
}

@Composable
private fun ShotContent(modifier: Modifier) {
    val position = remember { positionFromFen(NAJDORF) }
    Box(
        modifier.clearAndSetSemantics {
            contentDescription = "Example: a Najdorf position with a reply you haven't prepared, Bc4, met 1 in 67 games; a correct answer; 35 moves due today."
        },
        contentAlignment = Alignment.Center,
    ) {
        if (position != null) {
            Board(
                position = position,
                modifier = Modifier.size(250.dp).rotate(-5f).shadow(24.dp, RoundedCornerShape(16.dp)).clip(RoundedCornerShape(16.dp)),
                orientation = Side.BLACK,
                lastMove = PlayedMove("a6", "a7a6"),
                arrows = listOf(
                    BoardArrow(boardSquare(2, 0), boardSquare(6, 4), BoardArrow.Style.Opponent, width = 0.2),
                    BoardArrow(boardSquare(5, 0), boardSquare(2, 3), BoardArrow.Style.Gap, width = 0.16, dashed = true),
                ),
            )
        }
        FloatingCard(Modifier.offset(x = (-88).dp, y = 130.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Bc4", style = MaterialTheme.typography.titleMedium)
                Text("1 in 67", style = tabularDigits(MaterialTheme.typography.bodyMedium), color = MaterialTheme.colorScheme.onSurfaceVariant)
                StatusBadge("Gap", meaning = ThemeColor.todo)
            }
        }
        FloatingCard(Modifier.offset(x = 118.dp, y = (-112).dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = ThemeColor.correct.color, modifier = Modifier.size(20.dp))
                Text("Correct", style = MaterialTheme.typography.labelLarge, color = ThemeColor.correct.color)
            }
        }
        FloatingCard(Modifier.offset(x = 136.dp, y = 60.dp)) {
            Column {
                Text("35", style = tabularDigits(MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold)))
                Text("due today", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** A card from the app, raised over the shot: a raised surface, solid in either appearance. */
@Composable
private fun FloatingCard(modifier: Modifier, content: @Composable () -> Unit) {
    Surface(
        modifier,
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        tonalElevation = 2.dp,
        shadowElevation = 8.dp,
    ) {
        Box(Modifier.padding(horizontal = 12.dp, vertical = 9.dp)) { content() }
    }
}

private const val NAJDORF = "rnbqkb1r/1p2pppp/p2p1n2/8/3NP3/2N5/PPP2PPP/R1BQKB1R w KQkq - 0 6"
