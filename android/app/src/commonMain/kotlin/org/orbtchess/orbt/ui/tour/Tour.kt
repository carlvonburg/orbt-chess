package org.orbtchess.orbt.ui.tour

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import org.orbtchess.orbt.platform.Settings
import org.orbtchess.orbt.storage.RepertoireLibrary
import java.io.File

/**
 * The tour on the sample repertoire (`Tour.swift`): offered with the sample, started from the
 * Tour section in Today's place, then one step at a time, each a control to use, spotlighted by
 * [TourSpotlight] with everything else dimmed and blocked. A step moves on when the user does
 * what it asks, so they fill a gap of the sample and meet coverage, Biggest Gap, saving and
 * Study on the way, and end at New Repertoire for their own. Skip Tour ends it at any step.
 *
 * The step is kept in the settings (the Swift app's UserDefaults keys), so the tour goes on
 * where it was after a restart. One per app ([org.orbtchess.orbt.AppModel.tour]).
 */
class TourGuide(private val settings: Settings) {
    enum class Step {
        Off,

        /** The Tour section offers Start Tour; the spotlight begins on the overview. */
        Ready,
        Browse,
        BiggestGap,
        Answer,

        /** A reply to your answer still needs one. */
        Extend,

        /** Coverage is reached. */
        Save,
        Study,

        /** In Study, with a card that doesn't block. */
        Studying,

        /** Back in the library, where New Repertoire opens for the user's own repertoire. */
        Finish;

        /** The controls this step asks for; the rest of the screen is blocked. */
        val targets: List<Target>
            get() = when (this) {
                Off, Ready, Studying, Finish -> emptyList()
                Browse -> listOf(Target.BrowseButton)
                BiggestGap -> listOf(Target.BiggestGap)
                Answer -> listOf(Target.Candidates)
                Extend -> listOf(Target.Replies)
                Save -> listOf(Target.Save, Target.Analysis)
                Study -> listOf(Target.StudyBranch)
            }

        val title: String
            get() = when (this) {
                Off, Ready, Finish -> ""
                Studying -> "Learn It"
                Browse -> "Gaps"
                BiggestGap -> "Find a Gap"
                Answer -> "Your Answer"
                Extend -> "Which Replies Need an Answer"
                Save -> "Coverage Target Reached"
                Study -> "Gap Closed. Now Learn It"
            }

        val message: String
            get() = when (this) {
                Off, Ready, Finish -> ""
                Studying -> "Play your moves on the board; the app plays the replies. Stuck? Tap Hint."
                Browse -> "Gaps are replies opponents at your level play often that this repertoire doesn't answer yet. Tap Browse / Edit to fill them."
                BiggestGap -> "Biggest Gap jumps to the unanswered reply you'll meet most often. Tap it."
                Answer -> "Below are your candidates: how often each is played and how it scores. Tap the one you'd play."
                Extend -> "Now it's the opponent's turn. A reply with a Covered bar is played often enough (Seen 1 in 20 games or more) to need your answer; \"Not needed\" ones are rarer. Tap a reply that needs covering."
                Save -> "Every reply here is rarer than 1 in 20 games, so this line is covered. Tap Save to add it. Not sure about a move? Analysis checks it with Stockfish first."
                Study -> "Coverage went up. Tap Study Branch to practise the line you just added: moves you miss come back sooner."
            }
    }

    /** What a step spotlights; views mark themselves with [tourTarget]. */
    enum class Target { BrowseButton, BiggestGap, Board, Candidates, Replies, Save, Analysis, StudyBranch }

    var step: Step by mutableStateOf(Step.entries.getOrNull(settings.getInt(STEP_KEY) ?: 0) ?: Step.Off)
        private set

    private fun go(to: Step) {
        step = to
        settings.putInt(STEP_KEY, to.ordinal)
    }

    /** Tour screens on screen ([TourScreen]); the spotlight shows only over them. */
    var screens: Int by mutableIntStateOf(0)
        internal set

    /** Each target's parts on screen, in root coordinates, with the view that reported each. */
    private val parts = mutableStateMapOf<Target, Map<Int, Pair<Any, Rect>>>()

    /** The targets on screen; a target made of several views (the candidate rows) is their union. */
    val frames: Map<Target, Rect>
        get() = parts.mapNotNull { (target, parts) ->
            parts.values.map { it.second }.reduceOrNull { a, b ->
                Rect(minOf(a.left, b.left), minOf(a.top, b.top), maxOf(a.right, b.right), maxOf(a.bottom, b.bottom))
            }?.let { target to it }
        }.toMap()

    /**
     * Reports where a target's [part] is ([frame] null: gone). A view that goes clears only its
     * own frame, not the one a view replacing it (same target and part) already reported.
     */
    internal fun set(target: Target, part: Int, owner: Any, frame: Rect?) {
        val current = parts[target].orEmpty()
        if (frame != null) {
            if (current[part]?.let { it.first === owner && it.second == frame } == true) return
            parts[target] = current + (part to (owner to frame))
        } else if (current[part]?.first === owner) {
            parts[target] = current - part
        }
    }

    /** Offers the tour: the Tour section with Start Tour. */
    fun start() {
        markOffered()
        go(Step.Ready)
    }

    /** Whether the first launch has added the sample and offered the tour (once per device). */
    val wasOffered: Boolean get() = settings.getBoolean(OFFERED_KEY) == true

    /**
     * The first launch found repertoires already (another device, an earlier version): no
     * sample, now or when they are deleted later.
     */
    fun markOffered() = settings.putBoolean(OFFERED_KEY, true)

    fun skip() = go(Step.Off)

    /** Moves on when the tour is at [from]. */
    fun advance(from: Step, to: Step) {
        if (step == from) go(to)
    }

    /** The draft changed while the tour builds the line: your move, a reply, or done. */
    fun draftChanged(to: Step) {
        if (step in listOf(Step.Answer, Step.Extend, Step.Save) && step != to) go(to)
    }

    /** The answer was saved: one gap filled is enough, on to studying it. */
    fun saved() {
        if (step == Step.Save) go(Step.Study)
    }

    companion object {
        const val STEP_KEY = "tourStep"
        const val OFFERED_KEY = "tourOffered"

        /** The bundled sample, where the tour's tips show. */
        fun isSample(pgn: File): Boolean = RepertoireLibrary.isSample(pgn)
    }
}

/** The app's tour, for the views that mark targets (provided by the shell). */
val LocalTourGuide = staticCompositionLocalOf<TourGuide?> { null }

/**
 * Marks this view as a tour target: the spotlight cuts it out at the steps that name it.
 * [part]: one of several views that make up the target; null: not part of it (a later row).
 */
@Composable
fun Modifier.tourTarget(target: TourGuide.Target, part: Int? = 0): Modifier {
    val guide = LocalTourGuide.current ?: return this
    if (part == null) return this
    val owner = remember { Any() }
    DisposableEffect(guide, target, part) {
        onDispose { guide.set(target, part, owner, null) }
    }
    return onGloballyPositioned { guide.set(target, part, owner, it.boundsInRoot()) }
}

/**
 * A screen of the tour ([running]: it shows the sample): while one is on screen, the window's
 * [TourSpotlight] dims everything around the step's targets.
 */
@Composable
fun TourScreen(running: Boolean) {
    val guide = LocalTourGuide.current ?: return
    if (!running) return
    DisposableEffect(guide) {
        guide.screens += 1
        onDispose { guide.screens -= 1 }
    }
}
