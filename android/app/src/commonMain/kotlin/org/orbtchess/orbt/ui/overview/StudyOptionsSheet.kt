package org.orbtchess.orbt.ui.overview

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.DeckLimits
import org.orbtchess.orbt.core.NewMoveOrder
import org.orbtchess.orbt.core.PracticeMode
import org.orbtchess.orbt.core.newMoveOrderTitle
import org.orbtchess.orbt.core.practiceModeTitle
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.components.DialogButtons
import org.orbtchess.orbt.ui.components.FormColumn
import org.orbtchess.orbt.ui.components.LocalWideWindow
import org.orbtchess.orbt.ui.components.defaultAction
import org.orbtchess.orbt.ui.components.LocalWideForm
import org.orbtchess.orbt.ui.components.NumberField
import org.orbtchess.orbt.ui.components.WideRow

/**
 * A repertoire's study options (`StudyOptionsSheet` in LibraryView.swift, Anki's deck options):
 * the default daily limits or its own, its new move order and practice mode. One-day changes are custom study,
 * from the overview. The content of a Material bottom sheet the shell shows.
 *
 * @param onDone closes the sheet.
 */
@Composable
fun StudyOptionsSheet(
    app: AppModel,
    document: RepertoireDocument,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val preset = app.training
    var draft by remember(document) { mutableStateOf(DailyPracticeDraft.of(document.sidecar)) }
    val useDefaults = draft.useDefaultLimits
    // Rows on the sheet's own surface.
    val rowColors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0f))

    // A dialog (a wide window): Cancel and Save at its bottom, Enter saves; a phone's sheet has
    // them beside its title.
    val wide = LocalWideWindow.current
    val save = {
        document.updateStudySettings(draft.limits, draft.practiceMode, draft.newMoveOrder)
        onDone()
    }
    Column(modifier.defaultAction(wide, save)) {
        FormColumn(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(bottom = 16.dp)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("${document.name} Options", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                if (!wide) {
                    TextButton(onClick = onDone, shapes = ButtonDefaults.shapes()) { Text("Cancel") }
                    Button(shapes = ButtonDefaults.shapes(), onClick = save) { Text("Save") }
                }
            }

            FormSection(
                "Daily limits",
                footer = if (useDefaults) {
                    "From Settings. Turn off to set limits for this repertoire."
                } else {
                    "Every day, for this repertoire only. To study more just today, use Study More Today in the overview."
                },
            ) {
                ListItem(
                    trailingContent = { Switch(checked = useDefaults, onCheckedChange = null) },
                    colors = rowColors,
                    modifier = Modifier.toggleable(useDefaults, role = Role.Switch) { on ->
                        draft = draft.useDefaults(on, preset.newPerDay, preset.reviewsPerDay)
                    },
                ) { Text("Use Default Limits") }
                val newLimit = draft.limits.newLimit?.toInt() ?: preset.newPerDay
                val reviewLimit = draft.limits.reviewLimit?.toInt() ?: preset.reviewsPerDay
                val onNew: (Int) -> Unit = { draft = draft.copy(limits = draft.limits.copy(newLimit = it.toLong())) }
                val onReviews: (Int) -> Unit = { draft = draft.copy(limits = draft.limits.copy(reviewLimit = it.toLong())) }
                if (LocalWideForm.current) {
                    WideRow("New moves/day", 120.dp, colors = rowColors) { NumberField(newLimit, 0..9999, onNew, it, enabled = !useDefaults) }
                    WideRow("Maximum reviews/day", 120.dp, colors = rowColors) { NumberField(reviewLimit, 0..9999, onReviews, it, enabled = !useDefaults) }
                } else {
                    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        LimitField("New moves/day", newLimit, !useDefaults, onNew)
                        LimitField("Maximum reviews/day", reviewLimit, !useDefaults, onReviews)
                    }
                }
            }

            val order = draft.newMoveOrder ?: preset.newMoveOrder
            FormSection(
                "New lines",
                footer = if (draft.newMoveOrder == null) "The default, set in Settings." else "Only for this repertoire.",
            ) {
                Column(Modifier.selectableGroup()) {
                    for (option in NewMoveOrder.entries) {
                        ListItem(
                            selected = option == order,
                            onClick = { draft = draft.copy(newMoveOrder = option) },
                            supportingContent = { Text(option.detail) },
                            leadingContent = { RadioButton(selected = option == order, onClick = null) },
                            colors = rowColors,
                        ) { Text(newMoveOrderTitle(option)) }
                    }
                }
                if (draft.newMoveOrder != null) {
                    TextButton(onClick = { draft = draft.copy(newMoveOrder = null) }, shapes = ButtonDefaults.shapes(), modifier = Modifier.padding(horizontal = 8.dp)) {
                        Text("Use Default (${newMoveOrderTitle(preset.newMoveOrder)})")
                    }
                }
            }

            val mode = draft.practiceMode ?: preset.practiceMode
            FormSection(
                "Practice",
                footer = if (draft.practiceMode == null) "The default, set in Settings." else "Only for this repertoire.",
            ) {
                Column(Modifier.selectableGroup()) {
                    for (option in PracticeMode.entries) {
                        ListItem(
                            selected = option == mode,
                            onClick = { draft = draft.copy(practiceMode = option) },
                            supportingContent = { Text(option.detail) },
                            leadingContent = { RadioButton(selected = option == mode, onClick = null) },
                            colors = rowColors,
                        ) { Text(practiceModeTitle(option)) }
                    }
                }
                if (draft.practiceMode != null) {
                    TextButton(onClick = { draft = draft.copy(practiceMode = null) }, shapes = ButtonDefaults.shapes(), modifier = Modifier.padding(horizontal = 8.dp)) {
                        Text("Use Default (${practiceModeTitle(preset.practiceMode)})")
                    }
                }
            }
        }
        if (wide) DialogButtons("Save", save, onCancel = onDone)
    }
}

/** A daily limit, typed (Material has no stepper): 0 to 9999. */
@Composable
private fun LimitField(label: String, value: Int, enabled: Boolean, onChange: (Int) -> Unit) {
    // Keyed by the value shown, so turning the defaults on or off shows the right number.
    var text by remember(value, enabled) { mutableStateOf(value.toString()) }
    OutlinedTextField(
        value = text,
        onValueChange = { new ->
            text = new.filter(Char::isDigit).take(4)
            text.toIntOrNull()?.let(onChange)
        },
        label = { Text(label) },
        enabled = enabled,
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = Modifier.fillMaxWidth(),
    )
}

/**
 * A repertoire's daily limits, new move order and practice mode (`DailyPracticeDraft`): the
 * defaults from Settings, or its own (Anki's "This deck" limits). [newMoveOrder] and
 * [practiceMode] null use the default.
 */
private data class DailyPracticeDraft(val limits: DeckLimits, val newMoveOrder: NewMoveOrder?, val practiceMode: PracticeMode?) {
    /** On: no limits of its own. Off: this repertoire's own limits, starting from the defaults. */
    val useDefaultLimits: Boolean get() = limits.newLimit == null && limits.reviewLimit == null

    fun useDefaults(on: Boolean, newPerDay: Int, reviewsPerDay: Int): DailyPracticeDraft = copy(
        limits = if (on) DeckLimits(null, null, null, null) else limits.copy(newLimit = newPerDay.toLong(), reviewLimit = reviewsPerDay.toLong()),
    )

    companion object {
        fun of(sidecar: RepertoireDocument.SidecarValues): DailyPracticeDraft {
            // Limits for one day only are no longer offered; drop any left over.
            val limits = (sidecar.limits ?: DeckLimits(null, null, null, null)).copy(newLimitToday = null, reviewLimitToday = null)
            return DailyPracticeDraft(limits, sidecar.newMoveOrder, sidecar.practiceMode)
        }
    }
}

/** Which line of new moves comes next. Either way a line is learned to its end. */
internal val NewMoveOrder.detail: String
    get() = when (this) {
        NewMoveOrder.MOST_LIKELY_FIRST -> "The line you're most likely to meet next, in any opening."
        NewMoveOrder.ONE_OPENING_AT_A_TIME -> "Every line of an opening before the next opening."
    }

/** Who plays your moves on the way to the ones you're asked. */
internal val PracticeMode.detail: String
    get() = when (this) {
        PracticeMode.INDIVIDUAL_MOVES -> "The app plays the moves leading up to the ones you're asked."
        PracticeMode.COMPLETE_LINES_EVERY_TIME -> "You play all your moves on every line."
        PracticeMode.COMPLETE_LINES_ONCE_PER_SESSION -> "You play your moves the first time they come up; after that the app does."
    }
