package org.orbtchess.orbt.ui

import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.storage.NodeId
import org.orbtchess.orbt.storage.ROOT_NODE

/**
 * Every screen the app can show, typed (`LibraryRoute` and the sheets of the Swift app). Screens
 * ask for one with `navigate(destination)`; the shell ([AppShell]) decides where it goes: pushed
 * on the library's panes, as a full-window screen, or as a bottom sheet, and makes the model it
 * needs. A screen never builds another screen itself.
 */
sealed interface Destination {
    /** The repertoires (the list pane; the Repertoires tab on a phone). */
    data object Library : Destination

    /** A repertoire's overview: coverage, Study, Edit Lines (the detail pane). */
    data class Overview(val entryId: String) : Destination

    /** A repertoire's settings: name, side, coverage database and target (full window). */
    data class RepertoireSettings(val entryId: String) : Destination

    /** A repertoire's study options: daily limits, practice mode (bottom sheet). */
    data class StudyOptions(val entryId: String) : Destination

    /** The step-by-step setup of a new, imported or dropped-in repertoire (full window). */
    data class Setup(val mode: SetupMode) : Destination

    /**
     * Build (Browse in the Swift app): the move tree with the explorer and coverage. From the
     * start, or from [start] (Study's "Show in Build", a weakest move); [showGaps] opens the gap
     * list over it.
     */
    data class Builder(val entryId: String, val start: NodeId? = null, val showGaps: Boolean = false) : Destination

    /** Study, Learn More, Practice or one branch of a repertoire. */
    data class Drill(val entryId: String, val kind: DrillKind) : Destination

    /** Today's moves of every repertoire that has some, one repertoire after another. */
    data class StudyAll(val entryIds: List<String>) : Destination

    /**
     * The analysis board on the position on the board, with its move history: [moves] played
     * from [startFen] (null: the standard position), seen from [orientation]. Leaving it for
     * Build puts the line on the builder it came from as its draft; leaving it for Study drops it.
     */
    data class Analysis(
        val entryId: String,
        val startFen: String?,
        val moves: List<PlayedMove>,
        val orientation: Side,
        val origin: AnalysisOrigin,
    ) : Destination

    /** Statistics of every repertoire or one (the Statistics tab on a phone; beside each overview on wide windows). */
    data class Statistics(val scope: StatisticsScope) : Destination

    /** Anki's Card Info for the move at [node] (bottom sheet). */
    data class CardInfo(val entryId: String, val node: NodeId) : Destination

    /** The app's settings (full window). */
    data object Settings : Destination

    /** About, the licenses of the libraries the app uses (full window, from Settings). */
    data object Acknowledgements : Destination
}

/** Which study a drill runs (`LibraryRoute.study`, `.learnMore`, `.practice`, `.branch`). */
sealed interface DrillKind {
    /** Today's due moves (Anki's deck). */
    data object Study : DrillKind

    /** Study with today's new limit raised (Anki's custom study). */
    data object LearnMore : DrillKind

    /** Every studied move under a position, due or not (Anki's filtered deck): Practice. */
    data class Practice(val node: NodeId = ROOT_NODE) : DrillKind

    /** Today's moves under one position (Anki's subdeck): Study Branch in Build. */
    data class Branch(val node: NodeId) : DrillKind
}

/** Where the analysis board was opened from. */
enum class AnalysisOrigin {
    /** Build: going back hands the line to the builder it came from. */
    Build,

    /** Study: opening it counted as Again; going back drops it. */
    Study,
}

/** Statistics of every repertoire, or of one. */
sealed interface StatisticsScope {
    data object All : StatisticsScope
    data class Repertoire(val entryId: String) : StatisticsScope
}

/** What the setup flow sets up (`RepertoireSetupFlow.Mode`). */
sealed interface SetupMode {
    /** A new repertoire, its side already chosen when started from the empty library. */
    data class New(val side: Side? = null) : SetupMode

    /** A PGN picked from Files: nothing is written until it is added. */
    class Importing(val data: ByteArray, val name: String) : SetupMode

    /** A PGN dropped into the folder without settings; its name is its file's. */
    data class SetUp(val entryId: String) : SetupMode
}
