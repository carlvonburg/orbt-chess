package org.orbtchess.orbt.ui.tips

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.vector.ImageVector
import org.orbtchess.orbt.platform.Settings
import org.orbtchess.orbt.ui.builder.BuilderSymbols
import org.orbtchess.orbt.ui.components.Symbols

/**
 * The tips (`AppTips.swift`, TipKit there): what the screens can't say on their own, all in
 * Browse and Study: how a line is entered and saved, what Biggest Gap does, how to study what
 * was saved. Each shows where it applies and goes for good once its action is done, or once it
 * has been shown, whether or not it was read (Apple's HIG and Material's guidance alike:
 * help in context rather than one flow). Never more than one on screen: each is shown in a state
 * the others aren't, and a screen shows the first of its tips whose rule holds ([first], TipKit's
 * `TipGroup(.firstAvailable)`). Settings › Show Tips Again brings them back.
 *
 * Material has no TipKit: a tip is drawn with Material's own parts ([TipAnchor]'s rich tooltip,
 * [TipCard]'s card), and this keeps what TipKit keeps: which tips are done (in the settings, per
 * generation) and the rules' transient state. One per app ([org.orbtchess.orbt.AppModel.tips]).
 */
class Tips(private val settings: Settings) {
    /**
     * Part of every tip's key: Show Tips Again starts a new generation, whose tips aren't done. A
     * time, not a count: a generation is never used twice (a count can come back to one whose
     * tips are done, after the settings were reset or restored).
     */
    private var generation: Long = settings.getLong(GENERATION_KEY) ?: 0L

    /** The tips done in this generation (read once; written through to the settings). */
    private val done = mutableStateMapOf<Tip, Boolean>().apply { load() }

    private fun MutableMap<Tip, Boolean>.load() {
        clear()
        for (tip in Tip.entries) put(tip, settings.getBoolean(key(tip)) == true)
    }

    private fun key(tip: Tip) = "tip.${tip.key}.$generation"

    fun isDone(tip: Tip): Boolean = done[tip] == true

    /**
     * Done for good: its action was performed (TipKit's `invalidate(reason: .actionPerformed)`),
     * it was closed, or it has been shown once (`MaxDisplayCount(1)`).
     */
    fun invalidate(tip: Tip) {
        if (isDone(tip)) return
        done[tip] = true
        settings.putBoolean(key(tip), true)
    }

    /** The first tip whose rule holds and that isn't done (TipKit's `.firstAvailable`). */
    fun first(vararg rules: Pair<Tip, Boolean>): Tip? = rules.firstOrNull { (tip, holds) -> holds && !isDone(tip) }?.first

    /** Every tip again (Settings › Show Tips Again). */
    fun showAgain() {
        generation = System.currentTimeMillis() / 1000
        settings.putLong(GENERATION_KEY, generation)
        done.load()
        justSaved = false
    }

    /**
     * [Tip.StudyBranch]'s rule: a line was just saved while the gaps tip was done; cleared when a
     * new line is started or Browse is left. Transient, as the Swift app's tip parameters.
     */
    var justSaved: Boolean by mutableStateOf(false)

    companion object {
        /** The Swift app's UserDefaults key. */
        const val GENERATION_KEY = "tipsGeneration"
    }
}

/**
 * The tips, with the Swift app's titles and messages. In a message, `{icon}` stands for [icon],
 * the symbol of the button it names.
 */
enum class Tip(
    val key: String,
    val title: String,
    val message: String,
    val icon: ImageVector? = null,
    /** What a screen reader says for [icon] (nothing where the message names the button next to it). */
    val iconLabel: String = "",
) {
    // Browse.

    /**
     * Your move is missing on the board (a gap, or a new line at your move), on its badge; done
     * when you play a move there.
     */
    Answer(
        "answer", "Add Your Move",
        "Your repertoire has no move here yet. Tap one of the candidates below, which show how often each is played and how it scores, or play it on the board.",
    ),

    /**
     * The opponent's move in a new line, with replies that still need an answer, on the Covered
     * column; done when you play such a reply.
     */
    Replies(
        "replies", "Replies to Cover",
        "A bar means the reply is common enough to need your answer. \"Not needed\" ones are rarer than your target.",
    ),

    /**
     * A new line reached the coverage target (every reply is rarer than it), on its "Coverage
     * target reached" badge; done when such a line is saved.
     */
    LineCovered(
        "save", "Line Covered",
        "Every reply here is rarer than your target, so this line is long enough to save.",
    ),

    /**
     * A new line with a few of your moves, short of the coverage target, on its "New line, not
     * saved" badge; done when a line is saved. On a new repertoire the target can be many moves
     * away, and nothing needs to wait for it.
     */
    SaveDraft(
        "saveDraft", "Save as You Go",
        "{icon} saves these moves to your repertoire now, before every reply is covered. Come back to the line later to answer more.",
        Symbols.correct,
        iconLabel = "Save",
    ),

    /**
     * Saved moves on the board with gaps below them, on the counts under the board, naming the
     * bar's button; done when Biggest Gap is used.
     */
    BiggestGap(
        "biggestGap", "Gaps in This Line",
        "Common replies below this move that you don't answer yet. {icon} Biggest Gap jumps to the one you'll meet most often.",
        BuilderSymbols.biggestGap,
    ),

    /**
     * Right after a save, on the counts under the board: building leads to studying. Only at a
     * save after [BiggestGap] is done, so never just after that tip closes. Done when the Study
     * menu is used.
     */
    StudyBranch(
        "studyBranch", "Study These Moves",
        "{icon} Study Branch trains today's moves from here on: the app plays the replies and you answer.",
        Symbols.study,
    ),

    // Study.

    /** Your move is asked; done once a line is finished. */
    StudyCounts(
        "studyCounts", "Today's Moves",
        "The numbers are what's left today: new moves, moves you're learning (back within minutes) and learned moves to review. The underlined one is what you're asked now.",
    ),

    /** A new move is shown with its arrow; done when you play it. */
    NewMove(
        "newMove", "A New Move",
        "The arrow shows your move. Each time you get it right it comes back later; miss it and it comes back within minutes.",
    ),

    /** A move you've learned is asked; done when Hint is used. */
    Hint(
        "hint", "Can't Remember?",
        "{icon} Hint shows the move. It counts as a miss, so the move comes back sooner.",
        Symbols.hint,
    ),
}

/** The app's tips, for the views that show them (provided by the shell). */
val LocalTips = staticCompositionLocalOf<Tips?> { null }

/**
 * The tip a screen shows as a popover from what it explains (a phone's Browse, over the board),
 * for each [TipAnchor] to check; null where tips are inline ([TipCard]) or none applies.
 */
val LocalPopoverTip = staticCompositionLocalOf<Tip?> { null }
