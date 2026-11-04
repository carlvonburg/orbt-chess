package org.orbtchess.orbt.ui.settings

import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import org.orbtchess.orbt.ui.components.groupedTopAppBarColors
import org.orbtchess.orbt.ui.components.ListSection
import org.orbtchess.orbt.ui.components.GroupedBackground
import androidx.compose.foundation.Canvas
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
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearWavyProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberSliderState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import java.io.File
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.NewMoveOrder
import org.orbtchess.orbt.core.PracticeMode
import org.orbtchess.orbt.core.newMoveOrderTitle
import org.orbtchess.orbt.core.practiceModeTitle
import org.orbtchess.orbt.engine.EngineDefaults
import org.orbtchess.orbt.engine.EngineNetwork
import org.orbtchess.orbt.platform.FolderOpener
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.components.ChoiceButtonGroup
import org.orbtchess.orbt.ui.components.ChoiceDropdown
import org.orbtchess.orbt.ui.components.FormColumn
import org.orbtchess.orbt.ui.components.DialogCloseButton
import org.orbtchess.orbt.ui.components.DialogTitleBar
import org.orbtchess.orbt.ui.components.LocalDialogWindowTitle
import org.orbtchess.orbt.ui.components.LocalInDialog
import org.orbtchess.orbt.ui.components.LocalWideForm
import org.orbtchess.orbt.ui.components.NumberField
import org.orbtchess.orbt.ui.components.WideRow
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.library.startTour
import org.orbtchess.orbt.ui.overview.detail
import org.orbtchess.orbt.ui.theme.AppColor
import org.orbtchess.orbt.ui.theme.LocalAppColorSetting
import org.orbtchess.orbt.ui.theme.OrbtTheme
import org.orbtchess.orbt.ui.theme.Theme
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color
import org.orbtchess.orbt.ui.theme.systemDynamicColorScheme

/**
 * The app's settings (`SettingsView.swift`): Lichess account, sync, study defaults, app color,
 * engine (search time, lines, cloud evals, the full network), data, rating and starring, about. Full window,
 * as Android's settings screens: sections of list items, choices in dialogs; on a wide window
 * ([FormColumn]) each control beside its setting, as Windows' and the Mac's settings.
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
    val scrollBehavior = TopAppBarDefaults.pinnedScrollBehavior()
    Scaffold(
        // The page's title bar takes the scroll first (its color as content scrolls under); a dialog has none (unattached,
        // its scroll behavior would take every scroll and the content none).
        modifier = modifier.then(if (LocalInDialog.current) Modifier else Modifier.nestedScroll(scrollBehavior.nestedScrollConnection)),
        containerColor = GroupedBackground,
        topBar = {
            if (LocalInDialog.current) {
                DialogTitleBar("Settings")
            } else {
                TopAppBar(
                    title = { Text("Settings") },
                    colors = groupedTopAppBarColors(),
                    navigationIcon = {
                        IconButton(onClick = onBack, shapes = IconButtonDefaults.shapes()) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                    },
                    scrollBehavior = scrollBehavior,
                )
            }
        },
        // An Android dialog's Close (a desktop dialog window has the system's ✕).
        bottomBar = { if (LocalInDialog.current && LocalDialogWindowTitle.current == null) DialogCloseButton(onBack) },
    ) { padding ->
        FormColumn(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())) {
            LichessSection(app)
            if (app.sync.auth.providers.isNotEmpty()) SyncSection(app)
            StudyDefaultsSection(app)
            Section("Appearance", footer = "Buttons, selection and the board.") { AppColorRow() }
            EngineSettingsSection(app)
            DataSection(app)
            TourSection(app, onShown = {
                onBack()
                navigate(Destination.Library)
            })
            SupportSection(app)
            Section(null) {
                ListItem(
                    onClick = { navigate(Destination.Acknowledgements) },
                    leadingContent = { Icon(Symbols.info, contentDescription = null) },
                ) { Text("About ORBT Chess") }
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
            onClick = {
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
            leadingContent = { Icon(Symbols.tour, contentDescription = null) },
            supportingContent = error?.let { { Text(it, color = ThemeColor.failure.color) } },
        ) { Text("Show Tour") }
    }
}

/** A group of settings: its header, its rows as Material's segmented list, and a line of explanation under them. */
@Composable
internal fun Section(title: String?, footer: String? = null, content: @Composable () -> Unit) {
    ListSection(title, footer = footer, content = content)
}

/** A setting shown with its value (SwiftUI's `LabeledContent`), opening its choice when tapped; the value at the end on a wide page. */
@Composable
internal fun ValueRow(title: String, value: String, onClick: (() -> Unit)? = null) {
    val text: @Composable () -> Unit = { Text(value, style = tabularDigits(MaterialTheme.typography.bodyMedium)) }
    val wide = LocalWideForm.current
    val supporting = if (wide) null else text
    val trailing = if (wide) text else null
    if (onClick != null) {
        ListItem(onClick = onClick, supportingContent = supporting, trailingContent = trailing) { Text(title) }
    } else {
        ListItem(supportingContent = supporting, trailingContent = trailing) { Text(title) }
    }
}

/** A whole number setting: typed in place on a wide page, else its value opening a dialog. */
@Composable
private fun NumberRow(title: String, value: Int, range: IntRange, onChange: (Int) -> Unit) {
    if (LocalWideForm.current) {
        WideRow(title, NumberWidth) { NumberField(value, range, onChange, it) }
    } else {
        var editing by remember { mutableStateOf(false) }
        ValueRow(title, "$value") { editing = true }
        if (editing) NumberDialog(title, value, range, onDismiss = { editing = false }, onSave = onChange)
    }
}

/** One of several options: a menu in place on a wide page, else its value opening a dialog of radio buttons; each with its [detail]. */
@Composable
private fun <T> ChoiceRow(title: String, options: List<T>, selected: T, label: (T) -> String, detail: (T) -> String, onSelect: (T) -> Unit) {
    if (LocalWideForm.current) {
        WideRow(title, ControlWidth) { ChoiceDropdown(options, selected, onSelect, label, it, detail) }
    } else {
        var choosing by remember { mutableStateOf(false) }
        ValueRow(title, label(selected)) { choosing = true }
        if (choosing) {
            ChoiceDialog(title, options, selected, onDismiss = { choosing = false }, onSelect = onSelect) { option ->
                Column {
                    Text(label(option), style = MaterialTheme.typography.bodyLarge)
                    Text(detail(option), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

/** The width of a menu or button group beside its setting, and of a number field. */
private val ControlWidth = 240.dp
private val NumberWidth = 120.dp

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
                onClick = { scope.launch { auth.signOut() } },
            ) { Text("Sign Out", color = ThemeColor.failure.color) }
        } else {
            ListItem(
                onClick = {
                    scope.launch { if (auth.signIn(browser)) app.explorer.resume() }
                },
                leadingContent = { Icon(Symbols.signIn, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
            ) { Text("Sign in with Lichess", color = MaterialTheme.colorScheme.primary) }
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
    var newMoveOrder by remember { mutableStateOf(training.newMoveOrder) }
    Section(
        "Study defaults",
        footer = "For every repertoire. A repertoire's options can set its own. A line of new moves that has started is always finished.",
    ) {
        NumberRow("New moves/day", newPerDay, 0..9999) {
            newPerDay = it
            training.newPerDay = it
        }
        NumberRow("Maximum reviews/day", reviewsPerDay, 0..9999) {
            reviewsPerDay = it
            training.reviewsPerDay = it
        }
        ChoiceRow("New lines", NewMoveOrder.entries, newMoveOrder, ::newMoveOrderTitle, { it.detail }) {
            newMoveOrder = it
            training.newMoveOrder = it
        }
        ChoiceRow("Practice", PracticeMode.entries, practiceMode, ::practiceModeTitle, ::practiceDetail) {
            practiceMode = it
            training.practiceMode = it
        }
    }
}

/** Who plays your moves on the way to the ones you're asked (`PracticeMode.detail` in Swift). */
private fun practiceDetail(mode: PracticeMode): String = when (mode) {
    PracticeMode.INDIVIDUAL_MOVES -> "The app plays the moves leading up to the ones you're asked."
    PracticeMode.COMPLETE_LINES_EVERY_TIME -> "You play all your moves on every line."
    PracticeMode.COMPLETE_LINES_ONCE_PER_SESSION -> "You play your moves the first time they come up; after that the app does."
}

/** Rate ORBT Chess in the store it came from (none on the desktop) and star it on GitHub. */
@Composable
private fun SupportSection(app: AppModel) {
    val uri = LocalUriHandler.current
    Section(null, footer = "ORBT Chess is free and open source. A rating or a star helps other players find it.") {
        app.platform.storeReview?.let { store ->
            ListItem(
                onClick = { uri.openUri(store.pageUrl) },
                leadingContent = { Icon(Icons.Outlined.StarOutline, contentDescription = null) },
            ) { Text("Rate ORBT Chess") }
        }
        ListItem(
            onClick = { uri.openUri(AppLinks.SOURCE) },
            leadingContent = { Icon(Icons.Outlined.Code, contentDescription = null) },
        ) { Text("Star on GitHub") }
    }
}

/**
 * Where the data is: on the desktop the repertoires' folder and the app's own, each shown in the
 * system's file manager; on Android inside the app, where Files does not reach them, so the way
 * out is Export or the sync.
 */
@Composable
private fun DataSection(app: AppModel) {
    var cacheCount by remember { mutableIntStateOf(app.stats.entryCount) }
    val provider = app.sync.provider
    val folders = app.platform.folders
    val opener = app.platform.folderOpener
    val synced = provider?.let { "They are also in the ORBT Chess folder of ${it.title}. " } ?: ""
    Section(
        "Data",
        footer = if (opener != null) {
            "Repertoires are PGN files you can open in any chess program, each with its training progress " +
                "beside it. $synced" +
                "The statistics cache, coverage tables and the engine's network are fetched again when needed."
        } else {
            "Repertoires are PGN files kept inside the app, where Files and other apps do not reach them. " +
                "To use one elsewhere, export it from its settings" +
                (if (provider == null) " or sync with Dropbox or Google Drive. " else ". $synced") +
                "Statistics are cached in the app and fetched again when needed."
        },
    ) {
        if (opener != null) {
            FolderRow("Repertoires", folders.repertoires, opener)
            FolderRow("Statistics and downloads", folders.support, opener)
        } else {
            ValueRow("Repertoires", "Inside ORBT Chess")
        }
        ValueRow("Cached positions", NumberFormat.getIntegerInstance().format(cacheCount))
        ListItem(
            onClick = {
                app.stats.clear()
                cacheCount = app.stats.entryCount
            },
        ) { Text("Clear Statistics Cache", color = ThemeColor.failure.color) }
    }
}

/** A folder: its name, its path, and a button that shows it in the system's file manager. */
@Composable
private fun FolderRow(title: String, folder: File, opener: FolderOpener) {
    ListItem(
        supportingContent = { Text(folder.absolutePath) },
        trailingContent = {
            TextButton(onClick = { opener.open(folder) }, shapes = ButtonDefaults.shapes()) { Text(opener.label) }
        },
    ) { Text(title) }
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
        val onSearchTime: (Int) -> Unit = {
            searchTime = it
            defaults.searchTime = it
        }
        val onLines: (Int) -> Unit = {
            lines = it
            defaults.lines = it
        }
        val lineCounts = EngineDefaults.lineCounts.toList()
        if (LocalWideForm.current) {
            WideRow("Search time", ControlWidth + 80.dp) { modifier ->
                Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    SearchTimeSlider(times, searchTime, onSearchTime, Modifier.weight(1f))
                    Text("$searchTime s", style = tabularDigits(MaterialTheme.typography.bodyMedium), modifier = Modifier.width(40.dp))
                }
            }
            WideRow("Lines", ControlWidth) { ChoiceButtonGroup(lineCounts, lines, onLines, label = { "$it" }, modifier = it) }
        } else {
            ListItem(
                trailingContent = { Text("$searchTime s", style = tabularDigits(MaterialTheme.typography.bodyMedium)) },
                supportingContent = { SearchTimeSlider(times, searchTime, onSearchTime) },
            ) { Text("Search time") }
            ListItem(
                supportingContent = {
                    ChoiceButtonGroup(lineCounts, lines, onLines, label = { "$it" }, modifier = Modifier.padding(top = 8.dp))
                },
            ) { Text("Lines") }
        }
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

/** The engine's search time, in whole seconds, without a tick for each of the 30. */
@Composable
private fun SearchTimeSlider(times: IntRange, searchTime: Int, onChange: (Int) -> Unit, modifier: Modifier = Modifier) {
    val slider = rememberSliderState(searchTime.toFloat(), trackRange = times.first.toFloat()..times.last.toFloat())
    Slider(
        state = slider,
        onValueChange = {
            slider.value = it
            onChange(Math.round(it))
        },
        modifier = modifier,
    )
}

@Composable
private fun SwitchRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    ListItem(
        trailingContent = { Switch(checked = checked, onCheckedChange = null) },
        modifier = Modifier.selectable(selected = checked, role = Role.Switch) { onChange(!checked) },
    ) { Text(title) }
}

/** Stockfish's full network: download it, follow the download, use or remove it. */
@Composable
private fun EngineNetworkRows(network: EngineNetwork, use: Boolean, onUse: (Boolean) -> Unit) {
    when (val state = network.state) {
        EngineNetwork.State.Absent -> DownloadRow(network, null)
        is EngineNetwork.State.Failed -> DownloadRow(network, state.message)
        is EngineNetwork.State.Downloading -> ListItem(
            supportingContent = {
                LinearWavyProgressIndicator(
                    progress = { state.fraction.toFloat() },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
            },
            trailingContent = {
                IconButton(onClick = { network.cancel() }, shapes = IconButtonDefaults.shapes()) { Icon(Icons.Outlined.Close, contentDescription = "Cancel") }
            },
        ) { Text("Downloading full network") }
        EngineNetwork.State.Ready -> {
            SwitchRow("Use full network", use, onUse)
            ListItem(
                onClick = { network.remove() },
                leadingContent = { Icon(Symbols.delete, contentDescription = null, tint = ThemeColor.failure.color) },
            ) { Text("Remove Full Network", color = ThemeColor.failure.color) }
        }
    }
}

@Composable
private fun DownloadRow(network: EngineNetwork, error: String?) {
    ListItem(
        onClick = { network.start() },
        leadingContent = { Icon(Icons.Outlined.Download, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
        supportingContent = error?.let { { Text(it, color = ThemeColor.failure.color) } },
    ) { Text("Download Full Network (94 MB)", color = MaterialTheme.colorScheme.primary) }
}

// MARK: App color

/** The app color, each shown as a strip of the board it gives (as lichess shows its boards). */
@Composable
private fun AppColorRow() {
    val setting = LocalAppColorSetting.current
    if (LocalWideForm.current) {
        WideRow("Color", ControlWidth + 48.dp) { modifier ->
            Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                BoardStrip(setting.appColor, squares = 2, Modifier.width(36.dp).height(18.dp))
                ChoiceDropdown(AppColor.entries, setting.appColor, { setting.select(it) }, { it.title }, Modifier.weight(1f))
            }
        }
        return
    }
    var choosing by remember { mutableStateOf(false) }
    ListItem(
        onClick = { choosing = true },
        supportingContent = { Text(setting.appColor.title) },
        trailingContent = { BoardStrip(setting.appColor, squares = 2, Modifier.width(36.dp).height(18.dp)) },
    ) { Text("Color") }
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
        confirmButton = { TextButton(onClick = onDismiss, shapes = ButtonDefaults.shapes()) { Text("Cancel") } },
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
            TextButton(enabled = parsed != null, shapes = ButtonDefaults.shapes(), onClick = {
                parsed?.let(onSave)
                onDismiss()
            }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss, shapes = ButtonDefaults.shapes()) { Text("Cancel") } },
    )
}
