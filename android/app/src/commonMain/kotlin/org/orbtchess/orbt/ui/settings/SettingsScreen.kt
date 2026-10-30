package org.orbtchess.orbt.ui.settings

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import kotlinx.coroutines.CancellationException
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.library.startTour
import org.orbtchess.orbt.core.PracticeMode
import org.orbtchess.orbt.core.ROLLOVER_HOUR
import org.orbtchess.orbt.core.practiceModeTitle
import org.orbtchess.orbt.engine.EngineDefaults
import org.orbtchess.orbt.engine.EngineNetwork
import org.orbtchess.orbt.storage.TrainingDefaults
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.components.Format
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.theme.AppColor
import org.orbtchess.orbt.ui.theme.LocalAppColorSetting
import org.orbtchess.orbt.ui.theme.OrbtTheme
import org.orbtchess.orbt.ui.theme.Theme
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color
import org.orbtchess.orbt.ui.theme.systemDynamicColorScheme
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * The app's settings (`SettingsView.swift`): Lichess account, sync, study defaults, scheduling, app
 * color, engine (search time, lines, cloud evals, the full network), data, about. Full window,
 * as Android's settings screens: sections of list items, choices in dialogs.
 *
 * @param navigate [Destination.Acknowledgements] (About ORBT Chess).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    app: AppModel,
    navigate: (Destination) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                },
                scrollBehavior = scrollBehavior,
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())) {
            LichessSection(app)
            if (app.sync.auth.providers.isNotEmpty()) SyncSection(app)
            StudyDefaultsSection(app)
            SchedulingSection()
            Section("Appearance", footer = "Buttons, selection and the board.") { AppColorRow() }
            EngineSettingsSection(app)
            DataSection(app)
            TourSection(app, onShown = {
                onBack()
                navigate(Destination.Library)
            })
            Section(null) {
                ListItem(
                    headlineContent = { Text("About ORBT Chess") },
                    leadingContent = { Icon(Symbols.info, contentDescription = null) },
                    modifier = Modifier.clickable { navigate(Destination.Acknowledgements) },
                )
            }
        }
    }
}

// MARK: Sections

/** Show Tour: adds the sample again if it was deleted, and offers the tour in the library. */
@Composable
private fun TourSection(app: AppModel, onShown: () -> Unit) {
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    Section(null, footer = "Fills the gaps of a sample repertoire, adding it again if you deleted it.") {
        ListItem(
            headlineContent = { Text("Show Tour") },
            leadingContent = { Icon(Symbols.tour, contentDescription = null) },
            supportingContent = error?.let { { Text(it, color = ThemeColor.failure.color) } },
            modifier = Modifier.clickable {
                scope.launch {
                    try {
                        startTour(app)
                        onShown()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        error = e.message ?: e.toString()
                    }
                }
            },
        )
    }
}

/** A group of settings: its header, its rows and a line of explanation under them. */
@Composable
internal fun Section(title: String?, footer: String? = null, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
        if (title != null) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp).semantics { heading() },
            )
        }
        content()
        if (footer != null) {
            Text(
                footer,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
    }
}

/** A setting shown with its value (SwiftUI's `LabeledContent`), opening its choice when tapped. */
@Composable
internal fun ValueRow(title: String, value: String, onClick: (() -> Unit)? = null) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(value, style = tabularDigits(MaterialTheme.typography.bodyMedium)) },
        modifier = if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier,
    )
}

@Composable
private fun LichessSection(app: AppModel) {
    val auth = app.auth
    val browser = app.platform.authBrowser
    val scope = rememberCoroutineScope()
    Section("Lichess", footer = "Used only to read opening statistics from the Lichess explorer. No scopes are requested.") {
        if (auth.isSignedIn) {
            ValueRow("Signed in as", auth.username ?: "Lichess user")
            auth.expiresAt?.let { expires ->
                ValueRow(
                    "Session valid until",
                    Instant.ofEpochSecond(expires).atZone(ZoneId.systemDefault())
                        .format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)),
                )
            }
            ListItem(
                headlineContent = { Text("Sign Out", color = ThemeColor.failure.color) },
                modifier = Modifier.clickable { scope.launch { auth.signOut() } },
            )
        } else {
            ListItem(
                headlineContent = { Text("Sign in with Lichess", color = MaterialTheme.colorScheme.primary) },
                leadingContent = { Icon(Symbols.signIn, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
                modifier = Modifier.clickable {
                    scope.launch { if (auth.signIn(browser)) app.explorer.resume() }
                },
            )
            auth.lastError?.let { error ->
                Text(
                    error,
                    style = MaterialTheme.typography.bodySmall,
                    color = ThemeColor.failure.color,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }
        }
    }
}

@Composable
private fun StudyDefaultsSection(app: AppModel) {
    val training = app.training
    var newPerDay by remember { mutableIntStateOf(training.newPerDay) }
    var reviewsPerDay by remember { mutableIntStateOf(training.reviewsPerDay) }
    var practiceMode by remember { mutableStateOf(training.practiceMode) }
    var editing by remember { mutableStateOf<String?>(null) }
    Section(
        "Study defaults",
        footer = "For every repertoire. A repertoire's options can set its own. A line of new moves that has started is always finished.",
    ) {
        ValueRow("New moves/day", "$newPerDay") { editing = "new" }
        ValueRow("Maximum reviews/day", "$reviewsPerDay") { editing = "reviews" }
        ValueRow("Practice", practiceModeTitle(practiceMode)) { editing = "practice" }
    }
    when (editing) {
        "new" -> NumberDialog("New moves/day", newPerDay, 0..9999, onDismiss = { editing = null }) {
            newPerDay = it
            training.newPerDay = it
        }
        "reviews" -> NumberDialog("Maximum reviews/day", reviewsPerDay, 0..9999, onDismiss = { editing = null }) {
            reviewsPerDay = it
            training.reviewsPerDay = it
        }
        "practice" -> ChoiceDialog(
            title = "Practice",
            options = PracticeMode.entries,
            selected = practiceMode,
            onDismiss = { editing = null },
            onSelect = {
                practiceMode = it
                training.practiceMode = it
            },
        ) { mode ->
            Column {
                Text(practiceModeTitle(mode), style = MaterialTheme.typography.bodyLarge)
                Text(practiceDetail(mode), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** Who plays your moves on the way to the ones you're asked (`PracticeMode.detail` in Swift). */
private fun practiceDetail(mode: PracticeMode): String = when (mode) {
    PracticeMode.INDIVIDUAL_MOVES -> "The app plays the moves leading up to the ones you're asked."
    PracticeMode.COMPLETE_LINES_EVERY_TIME -> "You play all your moves on every line."
    PracticeMode.COMPLETE_LINES_ONCE_PER_SESSION -> "You play your moves the first time they come up; after that the app does."
}

@Composable
private fun SchedulingSection() {
    val preset = TrainingDefaults.preset
    fun steps(minutes: List<Double>) = minutes.joinToString(" ") { if (it < 60) "${it.toInt()}m" else "${(it / 60).toInt()}h" }
    Section("Scheduling", footer = "Anki's defaults with FSRS.") {
        ValueRow("Learning steps", steps(preset.learnSteps))
        ValueRow("Relearning steps", steps(preset.relearnSteps))
        ValueRow("Desired retention", Format.percent(preset.desiredRetention))
        ValueRow("Next day starts at", "$ROLLOVER_HOUR AM")
    }
}

@Composable
private fun DataSection(app: AppModel) {
    var cacheCount by remember { mutableIntStateOf(app.stats.entryCount) }
    val provider = app.sync.provider
    Section(
        "Data",
        footer = (if (provider == null) "Repertoires are stored on this device only. " else "") +
            "Repertoires are PGN files you can open in any chess program. " +
            "Statistics are cached on this device and fetched again when needed.",
    ) {
        ValueRow("Storage", if (provider == null) "On this device" else "On this device and in ${provider.title}")
        ValueRow("Cached positions", NumberFormat.getIntegerInstance().format(cacheCount))
        ListItem(
            headlineContent = { Text("Clear Statistics Cache", color = ThemeColor.failure.color) },
            modifier = Modifier.clickable {
                app.stats.clear()
                cacheCount = app.stats.entryCount
            },
        )
    }
}

// MARK: Engine

/** The analysis engine's settings (`EngineSettingsSection` in Swift; also for the analysis board). */
@Composable
fun EngineSettingsSection(app: AppModel, heading: String? = "Analysis engine") {
    val defaults = app.engineDefaults
    var searchTime by remember { mutableIntStateOf(defaults.searchTime) }
    var lines by remember { mutableIntStateOf(defaults.lines) }
    var cloud by remember { mutableStateOf(defaults.cloud) }
    var fullNetwork by remember { mutableStateOf(defaults.fullNetwork) }
    Section(
        heading,
        footer = "Stockfish 19 runs on this device, with its 1 MB network built in; the full network is stronger. " +
            "Where Lichess has a deep cloud evaluation of a position, it is shown and the engine does not run.",
    ) {
        val times = EngineDefaults.searchTimes
        ListItem(
            headlineContent = { Text("Search time") },
            trailingContent = { Text("$searchTime s", style = tabularDigits(MaterialTheme.typography.bodyMedium)) },
            supportingContent = {
                Slider(
                    value = searchTime.toFloat(),
                    onValueChange = {
                        searchTime = Math.round(it)
                        defaults.searchTime = searchTime
                    },
                    // Whole seconds, without a tick for each of the 30.
                    valueRange = times.first.toFloat()..times.last.toFloat(),
                )
            },
        )
        ListItem(
            headlineContent = { Text("Lines") },
            supportingContent = {
                val counts = EngineDefaults.lineCounts.toList()
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                    counts.forEachIndexed { i, n ->
                        SegmentedButton(
                            selected = lines == n,
                            onClick = {
                                lines = n
                                defaults.lines = n
                            },
                            shape = SegmentedButtonDefaults.itemShape(i, counts.size),
                            icon = {},
                            label = { Text("$n") },
                        )
                    }
                }
            },
        )
        SwitchRow("Lichess cloud evaluations", cloud) {
            cloud = it
            defaults.cloud = it
        }
        EngineNetworkRows(app.engineNetwork, fullNetwork) {
            fullNetwork = it
            defaults.fullNetwork = it
        }
    }
}

@Composable
private fun SwitchRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    ListItem(
        headlineContent = { Text(title) },
        trailingContent = { Switch(checked = checked, onCheckedChange = null) },
        modifier = Modifier.selectable(selected = checked, role = Role.Switch) { onChange(!checked) },
    )
}

/** Stockfish's full network: download it, follow the download, use or remove it. */
@Composable
private fun EngineNetworkRows(network: EngineNetwork, use: Boolean, onUse: (Boolean) -> Unit) {
    when (val state = network.state) {
        EngineNetwork.State.Absent -> DownloadRow(network, null)
        is EngineNetwork.State.Failed -> DownloadRow(network, state.message)
        is EngineNetwork.State.Downloading -> ListItem(
            headlineContent = { Text("Downloading full network") },
            supportingContent = {
                LinearProgressIndicator(
                    progress = { state.fraction.toFloat() },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
            },
            trailingContent = {
                IconButton(onClick = { network.cancel() }) { Icon(Icons.Outlined.Close, contentDescription = "Cancel") }
            },
        )
        EngineNetwork.State.Ready -> {
            SwitchRow("Use full network", use, onUse)
            ListItem(
                headlineContent = { Text("Remove Full Network", color = ThemeColor.failure.color) },
                leadingContent = { Icon(Symbols.delete, contentDescription = null, tint = ThemeColor.failure.color) },
                modifier = Modifier.clickable { network.remove() },
            )
        }
    }
}

@Composable
private fun DownloadRow(network: EngineNetwork, error: String?) {
    ListItem(
        headlineContent = { Text("Download Full Network (94 MB)", color = MaterialTheme.colorScheme.primary) },
        leadingContent = { Icon(Icons.Outlined.Download, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
        supportingContent = error?.let { { Text(it, color = ThemeColor.failure.color) } },
        modifier = Modifier.clickable { network.start() },
    )
}

// MARK: App color

/** The app color, each shown as a strip of the board it gives (as lichess shows its boards). */
@Composable
private fun AppColorRow() {
    val setting = LocalAppColorSetting.current
    var choosing by remember { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text("Color") },
        supportingContent = { Text(setting.appColor.title) },
        trailingContent = { BoardStrip(setting.appColor, squares = 2, Modifier.width(36.dp).height(18.dp)) },
        modifier = Modifier.clickable { choosing = true },
    )
    if (choosing) {
        ChoiceDialog(
            title = "Color",
            options = AppColor.entries,
            selected = setting.appColor,
            onDismiss = { choosing = false },
            onSelect = { setting.select(it) },
        ) { option ->
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(option.title, style = MaterialTheme.typography.bodyLarge)
                BoardStrip(option, squares = 6, Modifier.height(28.dp))
            }
        }
    }
}

/** A row of board squares in the board's colors for an app color. */
@Composable
private fun BoardStrip(color: AppColor, squares: Int, modifier: Modifier = Modifier) {
    val current = OrbtTheme.current
    val system = systemDynamicColorScheme(current.isDark)
    val board = remember(color, current.isDark, system) { Theme.make(color, current.isDark, system).board }
    Canvas(modifier.aspectRatio(squares.toFloat()).clip(RoundedCornerShape(3.dp)).clearAndSetSemantics {}) {
        val side = size.width / squares
        for (i in 0 until squares) {
            drawRect(if (i % 2 == 0) board.light else board.dark, Offset(i * side, 0f), Size(side, size.height))
        }
    }
}

// MARK: Dialogs

/** One of several options, as Android's settings choose them: a dialog of radio buttons. */
@Composable
internal fun <T> ChoiceDialog(
    title: String,
    options: List<T>,
    selected: T,
    onDismiss: () -> Unit,
    onSelect: (T) -> Unit,
    label: @Composable (T) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.selectableGroup().verticalScroll(rememberScrollState())) {
                for (option in options) {
                    Row(
                        Modifier.fillMaxWidth()
                            .selectable(selected = option == selected, role = Role.RadioButton) {
                                onSelect(option)
                                onDismiss()
                            }
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        RadioButton(selected = option == selected, onClick = null)
                        Column(Modifier.weight(1f)) { label(option) }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** A whole number in a range, typed (SwiftUI's stepper has no Material counterpart). */
@Composable
private fun NumberDialog(title: String, value: Int, range: IntRange, onDismiss: () -> Unit, onSave: (Int) -> Unit) {
    var text by remember { mutableStateOf(value.toString()) }
    val parsed = text.toIntOrNull()?.takeIf { it in range }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it.filter(Char::isDigit).take(4) },
                singleLine = true,
                isError = parsed == null,
                supportingText = { Text("${range.first}–${range.last}") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            )
        },
        confirmButton = {
            TextButton(enabled = parsed != null, onClick = {
                parsed?.let(onSave)
                onDismiss()
            }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
