package org.orbtchess.orbt.ui.overview

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.CloudDownload
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenu
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.LinearWavyProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import java.text.NumberFormat
import java.util.UUID
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.ExplorerDatabase
import org.orbtchess.orbt.core.ExplorerSpeed
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.databaseCacheKey
import org.orbtchess.orbt.core.databaseEloBins
import org.orbtchess.orbt.core.databaseFetchedAs
import org.orbtchess.orbt.core.databaseSummary
import org.orbtchess.orbt.core.newSidecar
import org.orbtchess.orbt.core.nowTimestamp
import org.orbtchess.orbt.core.title
import org.orbtchess.orbt.explorer.CoverageTables
import org.orbtchess.orbt.platform.Settings
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.components.ChoiceButtonGroup
import org.orbtchess.orbt.ui.components.ListSection
import org.orbtchess.orbt.ui.components.SymbolLabel
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color

// A repertoire's settings (`RepertoireSettingsForm.swift`): its side, where opponent move
// frequencies come from and how much to learn. Repertoire Settings shows them on one page; the
// setup flow (`ui.library.SetupScreen`) one step at a time.

/**
 * Where a repertoire's opponent move frequencies come from: games of one time control in one
 * rating bin, from an offline table downloaded when chosen. Blitz and rapid are Lichess games
 * (Lichess ratings), classical are over-the-board games (FIDE ratings, Lumbra's Gigabase).
 */
enum class CoverageSource(val title: String, val detail: String, internal val key: String) {
    Blitz("Blitz", "Lichess games, Lichess rating", "blitz"),
    Rapid("Rapid", "Lichess games, Lichess rating", "rapid"),
    Classical("Classical", "Over-the-board games, FIDE rating", "classical");

    fun database(rating: Int): ExplorerDatabase = when (this) {
        Blitz -> ExplorerDatabase.Lichess(listOf(rating.toLong()), listOf(ExplorerSpeed.BLITZ))
        Rapid -> ExplorerDatabase.Lichess(listOf(rating.toLong()), listOf(ExplorerSpeed.RAPID))
        Classical -> ExplorerDatabase.Otb(listOf(rating.toLong()))
    }

    /** Whether a table's database is one of this source's bins. */
    fun matches(database: ExplorerDatabase): Boolean = database == database(database.lowestRating)
}

/** The lowest rating of a database's bins (0 for masters). */
val ExplorerDatabase.lowestRating: Int
    get() = when (this) {
        is ExplorerDatabase.Lichess -> (ratings.minOrNull() ?: 0L).toInt()
        is ExplorerDatabase.Otb -> (ratings.minOrNull() ?: 0L).toInt()
        ExplorerDatabase.Masters -> 0
    }

/** "2000–2199", "<600", "2500+" for a bin's lower bound. */
fun ratingLabel(low: Int): String {
    val next = databaseEloBins().firstOrNull { it > low }?.toInt() ?: return "$low+"
    return if (low == 0) "<$next" else "$low–${next - 1}"
}

/** Named coverage targets ("cover moves seen once in N games"). */
enum class CoverageDepth(val games: Int, val title: String) {
    Standard(150, "Standard"),
    Advanced(200, "Advanced"),
    Tournament(300, "Tournament"),
    Bulletproof(400, "Bulletproof"),
    Overkill(600, "Overkill"),
    ExtremeOverkill(800, "Extreme overkill");

    companion object {
        fun of(games: Int): CoverageDepth? = entries.firstOrNull { it.games == games }
    }
}

/** Editable repertoire settings: color, coverage database and coverage target. */
data class RepertoireSettingsDraft(
    val color: Side = Side.WHITE,
    val source: CoverageSource = CoverageSource.Blitz,
    /** The rating bin (lower bound, one of `databaseEloBins()`). */
    val rating: Int = 1600,
    val targetGames: Int = CoverageDepth.Bulletproof.games,
) {
    val database: ExplorerDatabase get() = source.database(rating)

    /** The sidecar file of a new repertoire with these settings. */
    fun makeSidecar(): ByteArray =
        newSidecar(UUID.randomUUID().toString(), color, database, targetGames.toLong(), nowTimestamp())

    /** Remembers the games, rating and depth for the next new repertoire. */
    fun remember(settings: Settings) {
        settings.putString(SOURCE_KEY, source.key)
        settings.putInt(RATING_KEY, rating)
        settings.putInt(DEPTH_KEY, targetGames)
    }

    /** The same settings with another time control: the rating kept when it has a table, else the nearest. */
    fun withSource(source: CoverageSource, tables: List<ExplorerDatabase>): RepertoireSettingsDraft {
        val bins = tables.filter(source::matches).map { it.lowestRating }
        val rating = if (bins.isEmpty() || rating in bins) rating else bins.minBy { kotlin.math.abs(it - rating) }
        return copy(source = source, rating = rating)
    }

    companion object {
        private const val SOURCE_KEY = "newRepertoireSource"
        private const val RATING_KEY = "newRepertoireRating"
        private const val DEPTH_KEY = "newRepertoireDepth"

        /** An open repertoire's settings. Older repertoires chose several speeds and buckets, or
         *  the masters database: the closest single choice. */
        fun of(sidecar: RepertoireDocument.SidecarValues): RepertoireSettingsDraft {
            val (source, rating) = when (val database = sidecar.database) {
                ExplorerDatabase.Masters -> CoverageSource.Classical to 2200
                is ExplorerDatabase.Otb -> CoverageSource.Classical to (database.ratings.minOrNull()?.toInt() ?: 2200)
                is ExplorerDatabase.Lichess -> {
                    val speeds = database.speeds
                    val source = if (ExplorerSpeed.BLITZ in speeds || ExplorerSpeed.RAPID !in speeds) {
                        CoverageSource.Blitz
                    } else {
                        CoverageSource.Rapid
                    }
                    val low = database.ratings.minOrNull()?.toInt() ?: 1600
                    source to (databaseEloBins().lastOrNull { it <= low }?.toInt() ?: 1600)
                }
            }
            return RepertoireSettingsDraft(sidecar.color, source, rating, sidecar.targetGames)
        }

        /** The defaults with the last new repertoire's games, rating and depth (not its side):
         *  a second repertoire usually prepares for the same opponents. */
        fun lastUsed(settings: Settings): RepertoireSettingsDraft {
            val default = RepertoireSettingsDraft()
            return default.copy(
                source = CoverageSource.entries.firstOrNull { it.key == settings.getString(SOURCE_KEY) } ?: default.source,
                rating = settings.getInt(RATING_KEY) ?: default.rating,
                targetGames = settings.getInt(DEPTH_KEY) ?: default.targetGames,
            )
        }
    }
}

// MARK: Sections

/** A titled group of a settings page, with an explanation under it (a Form section): Material's segmented list, a segment per row. */
@Composable
fun FormSection(
    header: String?,
    modifier: Modifier = Modifier,
    footer: String? = null,
    content: @Composable () -> Unit,
) {
    ListSection(header, modifier, footer, content)
}

/** Every repertoire setting on one page (Repertoire Settings). */
@Composable
fun RepertoireSettingsForm(app: AppModel, draft: RepertoireSettingsDraft, onChange: (RepertoireSettingsDraft) -> Unit) {
    FormSection("I play") {
        SideSegments(draft.color, { onChange(draft.copy(color = it)) }, Modifier.padding(horizontal = 16.dp))
    }
    CoverageSourceSection(app, draft, onChange, list = false)
    DepthSection(draft.targetGames, { onChange(draft.copy(targetGames = it)) })
}

/** White or Black: Material 3 Expressive's connected button group. */
@Composable
fun SideSegments(side: Side, onChange: (Side) -> Unit, modifier: Modifier = Modifier) {
    ChoiceButtonGroup(listOf(Side.WHITE, Side.BLACK), side, onChange, label = { it.title }, modifier = modifier)
}

/**
 * Where opponent move frequencies come from: the time control, the rating bin and its table
 * (downloaded as soon as it is chosen). [list]: the setup flow's page, each time control with
 * whose games they are; else segmented buttons.
 */
@Composable
fun CoverageSourceSection(
    app: AppModel,
    draft: RepertoireSettingsDraft,
    onChange: (RepertoireSettingsDraft) -> Unit,
    list: Boolean,
) {
    val tables = app.coverage.selections
    val footer = sourceFooter(draft)
    if (list) {
        FormSection("Their games") {
            Column(Modifier.selectableGroup()) {
                for (source in CoverageSource.entries) {
                    ListItem(
                        selected = draft.source == source,
                        onClick = { onChange(draft.withSource(source, tables)) },
                        supportingContent = { Text(source.detail) },
                        leadingContent = { RadioButton(selected = draft.source == source, onClick = null) },
                    ) { Text(source.title) }
                }
            }
        }
        FormSection(null, footer = footer) {
            RatingPicker(app, draft, onChange, "Their rating")
        }
    } else {
        FormSection("Coverage database", footer = footer) {
            ChoiceButtonGroup(
                CoverageSource.entries, draft.source,
                onSelect = { onChange(draft.withSource(it, tables)) },
                label = { it.title },
                modifier = Modifier.padding(horizontal = 16.dp),
            )
            RatingPicker(app, draft, onChange, "Opponent rating")
        }
    }
}

private fun sourceFooter(draft: RepertoireSettingsDraft): String =
    if (draft.source == CoverageSource.Classical) {
        "Opponent move frequencies come from over-the-board games since the year 2000 at this average FIDE " +
            "rating (Lumbra's Gigabase, CC BY-NC 4.0), downloaded to this device. Only positions it doesn't " +
            "hold come from the Lichess explorer (${classicalBackup(draft)})."
    } else {
        "Opponent move frequencies come from Lichess ${draft.source.title.lowercase()} games at this average " +
            "rating, downloaded to this device. Positions it doesn't hold come from the Lichess explorer."
    }

/** Which Lichess games answer the positions a Classical table lacks. */
private fun classicalBackup(draft: RepertoireSettingsDraft): String {
    val backup = databaseFetchedAs(draft.database)
    if (backup == ExplorerDatabase.Masters) return "masters games"
    return "${databaseSummary(backup)}, one rating bin up, as Lichess ratings run higher than FIDE"
}

/**
 * The rating bins with a table for the chosen time control (Material's exposed dropdown), the
 * chosen table's download state, and the download itself, started as soon as a bin is chosen.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RatingPicker(app: AppModel, draft: RepertoireSettingsDraft, onChange: (RepertoireSettingsDraft) -> Unit, label: String) {
    val coverage = app.coverage
    val bins = coverage.selections.filter(draft.source::matches).map { it.lowestRating }.sorted()
    val options = if (draft.rating in bins) bins else (bins + draft.rating).sorted()
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded, { expanded = it }, Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        // The anchor's own click handling never opens the menu on the desktop when the box comes
        // after the screen's first frame (the setup's step 2; Compose Multiplatform material3
        // 1.13.0-beta01), so a click target over the field opens it; the anchor still places it.
        Box(Modifier.menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable, enabled = false)) {
            OutlinedTextField(
                value = ratingLabel(draft.rating),
                onValueChange = {},
                readOnly = true,
                label = { Text(label) },
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.matchParentSize().clickable(role = Role.DropdownList) { expanded = !expanded })
        }
        ExposedDropdownMenu(expanded, { expanded = false }) {
            for (bin in options) {
                DropdownMenuItem(
                    text = { Text(ratingLabel(bin)) },
                    onClick = {
                        expanded = false
                        onChange(draft.copy(rating = bin))
                    },
                )
            }
        }
    }
    TableDownloadRow(coverage, draft.database)
    // Not tied to this screen: the download finishes after it closes.
    LaunchedEffect(databaseCacheKey(draft.database), coverage.available.size) { coverage.ensure(draft.database) }
}

/** Whether the chosen table is on this device, its download, or a button to download it again. */
@Composable
private fun TableDownloadRow(coverage: CoverageTables, database: ExplorerDatabase) {
    val file = coverage.file(database)
    val fraction = file?.let { coverage.downloads[it.file] }
    val padding = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
    when {
        coverage.isReady(database) -> SecondaryLabel("On this device", Icons.Outlined.CheckCircle, padding)
        file != null && fraction != null -> Column(padding, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Downloading ${formatBytes(file.bytes)}", style = MaterialTheme.typography.bodyMedium)
            LinearWavyProgressIndicator(progress = { fraction.toFloat() }, modifier = Modifier.fillMaxWidth())
        }
        file != null -> RetryButton("Download Again", Icons.Outlined.Download, coverage, database)
        // The server's list was never read (offline since installing): the table may exist.
        !coverage.manifestKnown -> {
            SecondaryLabel("Downloads when you're online", Icons.Outlined.CloudDownload, padding)
            if (coverage.manifestFailed && !coverage.readingManifest) {
                RetryButton("Try Again", Icons.Outlined.Refresh, coverage, database)
            }
        }
        else -> SecondaryLabel(
            "Not available offline: coverage uses the Lichess explorer", Icons.Outlined.CloudOff, padding,
            MaterialTheme.typography.bodySmall,
        )
    }
    val error = file?.let { coverage.failures[it.file] }
    if (error != null && !coverage.isReady(database)) {
        Text(
            error,
            style = MaterialTheme.typography.bodySmall,
            color = ThemeColor.failure.color,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
    }
}

/**
 * Reads the server's list again and downloads the table, in the tables' scope: the button gives
 * way to the progress, which would cancel work started from it.
 */
@Composable
private fun RetryButton(text: String, icon: ImageVector, coverage: CoverageTables, database: ExplorerDatabase) {
    TextButton(
        shapes = ButtonDefaults.shapes(),
        onClick = { coverage.startRetry(database) },
        enabled = !coverage.readingManifest,
        modifier = Modifier.padding(horizontal = 4.dp),
    ) {
        SymbolLabel(text, icon)
    }
}

/** A symbol and its text in the secondary color (a `Label` with `.secondary` style). */
@Composable
internal fun SecondaryLabel(
    text: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    style: TextStyle = MaterialTheme.typography.bodyMedium,
) {
    CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurfaceVariant) {
        SymbolLabel(text, icon, modifier, style = style)
    }
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1_000_000_000 -> "%.1f GB".format(bytes / 1e9)
    bytes >= 1_000_000 -> "%.0f MB".format(bytes / 1e6)
    else -> "${(bytes / 1000).coerceAtLeast(1)} KB"
}

/**
 * How much to learn: the named coverage targets, or a custom one, as radio rows; each shows
 * "1 in N games" and a bar for how much study it takes.
 * [inSetup]: the setup flow's page, whose title asks the question.
 */
@Composable
fun DepthSection(targetGames: Int, onChange: (Int) -> Unit, inSetup: Boolean = false) {
    var customTarget by remember { mutableStateOf(false) }
    val isPreset = CoverageDepth.of(targetGames) != null
    FormSection(
        if (inSetup) null else "How much do you want to learn?",
        footer = "Every opponent move you would meet at least once in this many games must have an answer in " +
            "your repertoire. Deeper goals mean more lines to learn." +
            if (inSetup) " You can change this later in the repertoire's settings." else "",
    ) {
        Column(Modifier.selectableGroup()) {
            for (depth in CoverageDepth.entries) {
                DepthRow(depth.title, depth.games, selected = !customTarget && targetGames == depth.games) {
                    customTarget = false
                    onChange(depth.games)
                }
            }
            val custom = customTarget || !isPreset
            DepthRow("Custom", if (custom) targetGames else null, selected = custom) { customTarget = true }
            if (custom) CustomTarget(targetGames, onChange)
        }
    }
}

@Composable
private fun DepthRow(name: String, games: Int?, selected: Boolean, onClick: () -> Unit) {
    ListItem(
        selected = selected,
        onClick = onClick,
        supportingContent = games?.let { { Text("1 in ${NumberFormat.getIntegerInstance().format(it)} games") } },
        leadingContent = { RadioButton(selected = selected, onClick = null) },
        trailingContent = games?.let {
            {
                // Study time grows roughly with the number of games covered.
                LinearProgressIndicator(
                    progress = { (it / 960f).coerceAtMost(1f) },
                    modifier = Modifier.width(48.dp),
                    color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.primary.copy(alpha = 0.45f),
                    // Only the length: no track.
                    trackColor = MaterialTheme.colorScheme.surface.copy(alpha = 0f),
                    strokeCap = StrokeCap.Round,
                    gapSize = 0.dp,
                    drawStopIndicator = {},
                )
            }
        },
    ) { Text(name) }
}

/** A custom target, typed (Material has no stepper): 20 to 20,000 games. */
@Composable
private fun CustomTarget(targetGames: Int, onChange: (Int) -> Unit) {
    var text by remember { mutableStateOf(targetGames.toString()) }
    val value = text.toIntOrNull()
    val valid = value != null && value in 20..20_000
    Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        OutlinedTextField(
            value = text,
            onValueChange = { new ->
                text = new.filter(Char::isDigit).take(5)
                text.toIntOrNull()?.takeIf { it in 20..20_000 }?.let(onChange)
            },
            label = { Text("1 in … games") },
            supportingText = if (valid) null else ({ Text("From 20 to 20,000") }),
            isError = !valid,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}
