package org.orbtchess.orbt.ui.library

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.backhandler.BackHandler
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import orbt.app.generated.resources.Res
import orbt.app.generated.resources.piece_bk
import orbt.app.generated.resources.piece_wk
import org.jetbrains.compose.resources.painterResource
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.storage.RepertoireEntry
import org.orbtchess.orbt.storage.RepertoireLibrary
import org.orbtchess.orbt.ui.SetupMode
import org.orbtchess.orbt.ui.overview.CoverageSourceSection
import org.orbtchess.orbt.ui.overview.DepthSection
import org.orbtchess.orbt.ui.overview.FormSection
import org.orbtchess.orbt.ui.overview.RepertoireSettingsDraft
import org.orbtchess.orbt.ui.theme.OrbtTheme
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color

/**
 * A new, imported or dropped-in repertoire, set up one step at a time
 * (`RepertoireSetupFlow.swift`): its name and side, the opponents' games, how much to learn.
 * Each setting decides which replies are gaps, so each has a page; Repertoire Settings edits
 * them later on one page. Full window: close on the first page, back on the others.
 *
 * @param onDone the repertoire made or set up: the shell shows its overview (a new one opens on Build).
 * @param onCancel leaves without adding anything.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
fun SetupScreen(
    app: AppModel,
    mode: SetupMode,
    onDone: (RepertoireEntry) -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val setUpEntry = (mode as? SetupMode.SetUp)?.let { app.library.entry(it.entryId) }
    var name by remember {
        mutableStateOf(
            when (mode) {
                is SetupMode.New -> ""
                is SetupMode.Importing -> mode.name
                is SetupMode.SetUp -> setUpEntry?.name ?: ""
            },
        )
    }
    var draft by remember {
        val last = RepertoireSettingsDraft.lastUsed(app.platform.settings)
        mutableStateOf((mode as? SetupMode.New)?.side?.let { last.copy(color = it) } ?: last)
    }
    var step by remember { mutableIntStateOf(1) }
    var failure by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val canContinue = name.isNotBlank()

    val title = when (step) {
        1 -> when (mode) {
            is SetupMode.New -> "New Repertoire"
            is SetupMode.Importing -> "Import PGN"
            is SetupMode.SetUp -> "Set Up ${setUpEntry?.name ?: ""}"
        }
        2 -> "Your Opponents"
        else -> "How Much to Learn"
    }
    val finishTitle = when (mode) {
        is SetupMode.New -> "Create"
        is SetupMode.Importing -> "Add"
        is SetupMode.SetUp -> "Save"
    }

    fun finish() {
        scope.launch {
            try {
                val entry = when (mode) {
                    is SetupMode.New -> app.library.create(name, draft.makeSidecar())
                    is SetupMode.Importing -> app.library.importPgn(mode.data, name, draft.makeSidecar())
                    is SetupMode.SetUp -> {
                        val entry = setUpEntry ?: throw IllegalStateException("The file is no longer in the folder.")
                        app.library.saveSidecar(draft.makeSidecar(), entry)
                        app.library.entry(entry.id) ?: entry
                    }
                }
                draft.remember(app.platform.settings)
                onDone(entry)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // The name is on the first step.
                failure = e.message ?: e.toString()
                step = 1
            }
        }
    }

    // Back goes to the previous step (the shell closes the flow from the first).
    BackHandler(enabled = step > 1) { step -= 1 }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(title) },
                subtitle = { Text("Step $step of 3") },
                navigationIcon = {
                    if (step == 1) {
                        IconButton(onClick = onCancel) { Icon(Icons.Filled.Close, contentDescription = "Cancel") }
                    } else {
                        IconButton(onClick = { step -= 1 }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                    }
                },
                actions = {
                    if (step < 3) {
                        TextButton(onClick = { step += 1 }, enabled = canContinue) { Text("Next") }
                    } else {
                        Button(onClick = ::finish, modifier = Modifier.padding(end = 8.dp)) { Text(finishTitle) }
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())) {
            when (step) {
                1 -> {
                    FormSection("Name") {
                        if (mode is SetupMode.SetUp) {
                            Text(name, modifier = Modifier.padding(horizontal = 16.dp))
                        } else {
                            val focus = remember { FocusRequester() }
                            OutlinedTextField(
                                value = name,
                                onValueChange = { name = RepertoireLibrary.safeRepertoireName(it) },
                                placeholder = { Text("Najdorf") },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Next),
                                keyboardActions = KeyboardActions(onNext = { if (canContinue) step = 2 }),
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).focusRequester(focus),
                            )
                            if (mode is SetupMode.New) LaunchedEffect(Unit) { focus.requestFocus() }
                        }
                    }
                    FormSection("I play", footer = "You learn this side's moves and prepare for the other side's replies.") {
                        SidePicker(draft.color, { draft = draft.copy(color = it) }, Modifier.padding(horizontal = 16.dp))
                    }
                    failure?.let {
                        Text(it, color = ThemeColor.failure.color, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                    }
                }
                2 -> {
                    Text(
                        "Gaps are the replies your opponents play often that you haven't answered yet. They come from games at your opponents' level.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                    CoverageSourceSection(app, draft, { draft = it }, list = true)
                }
                else -> DepthSection(draft.targetGames, { draft = draft.copy(targetGames = it) }, inSetup = true)
            }
        }
    }
}

/** White or Black as two cards, each with its king as the board draws it. */
@Composable
fun SidePicker(side: Side, onChange: (Side) -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        SideCard(Side.WHITE, "White", side == Side.WHITE, Modifier.weight(1f)) { onChange(Side.WHITE) }
        SideCard(Side.BLACK, "Black", side == Side.BLACK, Modifier.weight(1f)) { onChange(Side.BLACK) }
    }
}

/** A side as a Material card: its king and its name; outlined in the primary color when selected. */
@Composable
fun SideCard(side: Side, title: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    OutlinedCard(
        onClick = onClick,
        modifier = modifier.clearAndSetSemantics {
            contentDescription = title
            role = Role.RadioButton
            this.selected = selected
        },
        border = if (selected) BorderStroke(2.dp, MaterialTheme.colorScheme.primary) else BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column(
            Modifier.fillMaxWidth().padding(vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            SideTile(side, 52.dp)
            Text(title, style = MaterialTheme.typography.titleMedium)
        }
    }
}

/**
 * A side's king on a square of its own color, as the board draws them: a white king on a light
 * square, a black king on a dark one, in light and dark appearance alike.
 */
@Composable
fun SideTile(side: Side, size: Dp = 44.dp) {
    val board = OrbtTheme.board
    Image(
        painterResource(if (side == Side.WHITE) Res.drawable.piece_wk else Res.drawable.piece_bk),
        contentDescription = null,
        modifier = Modifier.size(size)
            .background(if (side == Side.WHITE) board.light else board.dark, RoundedCornerShape(size * 0.18f))
            .padding(size * 0.08f),
    )
}
