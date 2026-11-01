package org.orbtchess.orbt.storage

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.orbtchess.orbt.core.Card
import org.orbtchess.orbt.core.Changes
import org.orbtchess.orbt.core.CoverageGap
import org.orbtchess.orbt.core.Counts
import org.orbtchess.orbt.core.DeckLimits
import org.orbtchess.orbt.core.DocumentListener
import org.orbtchess.orbt.core.Epd
import org.orbtchess.orbt.core.Explorer
import org.orbtchess.orbt.core.ExplorerDatabase
import org.orbtchess.orbt.core.ExplorerStats
import org.orbtchess.orbt.core.GraphParts
import org.orbtchess.orbt.core.Node
import org.orbtchess.orbt.core.NodeCoverage
import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.Position
import org.orbtchess.orbt.core.NewMoveOrder
import org.orbtchess.orbt.core.PracticeMode
import org.orbtchess.orbt.core.Progress
import org.orbtchess.orbt.core.RemainingLimits
import org.orbtchess.orbt.core.RepertoireDoc
import org.orbtchess.orbt.core.ReplyInfo
import org.orbtchess.orbt.core.RevlogEntry
import org.orbtchess.orbt.core.SchedTiming
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.StudyDefaults
import org.orbtchess.orbt.core.mergeRevlogData
import org.orbtchess.orbt.core.mergeSidecarData
import org.orbtchess.orbt.core.nowTimestamp
import org.orbtchess.orbt.core.openRepertoire
import org.orbtchess.orbt.core.schedTiming
import java.io.File
import java.io.IOException
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicReference

/** A node of the move tree, as the core numbers them. */
typealias NodeId = UInt

/** The tree's root (`RepertoireTree.rootID` in Swift). */
val ROOT_NODE: NodeId = 0u

/**
 * An open repertoire. The Rust core (`RepertoireDoc`) holds the tree, the sidecar and the
 * coverage and decides what each change means; this does the file IO it asks for: every edit
 * is written back to the PGN shortly after it happens, and changes made on another device are
 * handed to the core to merge (`applyRemote`, for the sync).
 *
 * Main-thread confined: `scope` runs on the main thread, and the core's own changes (stats
 * arriving, from any thread) hop to it. Compose reads `revision` (through the read-only views
 * below) and redraws when the core changes.
 */
class RepertoireDocument private constructor(
    entry: RepertoireEntry,
    val core: RepertoireDoc,
    private val scope: CoroutineScope,
) {
    var entryId: String by mutableStateOf(entry.id)
        private set
    var pgnFile: File by mutableStateOf(entry.pgnFile)
        private set
    var sidecarFile: File by mutableStateOf(entry.sidecarFile)
        private set
    var name: String by mutableStateOf(entry.name)
        private set

    /** Bumped on every change so views can refresh derived values. */
    var revision: ULong by mutableStateOf(0uL)
        private set
    var saveError: String? by mutableStateOf(null)
        private set
    var canUndo: Boolean by mutableStateOf(false)
        private set

    /** Told when the PGN was deleted by someone else (the sync). */
    var onRemoved: (() -> Unit)? = null
    /** Told, with the old entry id, when someone else renamed the PGN. */
    var onRenamed: ((String) -> Unit)? = null

    /** Runs the file IO off the main thread, one operation at a time, so saves land in order. */
    @OptIn(ExperimentalCoroutinesApi::class)
    private val writer = Dispatchers.IO.limitedParallelism(1)
    private var pgnSaveJob: Job? = null
    private var sidecarSaveJob: Job? = null
    /** Where the files are, read by the writer when each operation runs. */
    private val files = AtomicReference(Files(entry.pgnFile, entry.sidecarFile))
    /** Closing: no new saves are scheduled and remote changes are ignored. */
    private var isClosed = false
    /** The files are being deleted: nothing is written any more. */
    // Volatile: the writer reads it as each save runs, so a save already on its way writes nothing.
    @Volatile private var isDiscarded = false
    private var cachedCards: Pair<ULong, Map<Epd, Card>>? = null

    /** The opened core and what it asked for while opening. */
    class Loaded(val document: RepertoireDoc, val changes: List<Changes>)

    companion object {
        /** Reads and parses the files off the main thread (a large PGN takes a moment). */
        suspend fun load(pgnFile: File, sidecarFile: File, defaults: StudyDefaults, explorer: Explorer): Loaded =
            withContext(Dispatchers.IO) {
                val sidecar = FileAccess.read(sidecarFile)
                val text = FileAccess.read(pgnFile).toString(Charsets.UTF_8)
                val opened = openRepertoire(text, sidecar, defaults, explorer)
                Loaded(opened.document, listOf(opened.changes))
            }

        /** `loaded` comes from `load`; `scope` runs on the main thread. */
        fun create(entry: RepertoireEntry, loaded: Loaded, scope: CoroutineScope): RepertoireDocument {
            val document = RepertoireDocument(entry, loaded.document, scope)
            document.core.setListener(Listener(document))
            for (changes in loaded.changes) document.apply(changes)
            return document
        }
    }

    /** Applies what the core changed: refreshes views and schedules the saves it asks for. */
    fun apply(changes: Changes) {
        if (changes.revision != revision) revision = changes.revision
        canUndo = core.canUndo()
        changes.savePgnAfterMs?.let { schedulePgnSave(it.toLong()) }
        changes.saveSidecarAfterMs?.let { scheduleSidecarSave(it.toLong()) }
        cachedCards = null
    }

    /** Renames the PGN, sidecar and review log. The entry id changes with the file names. */
    suspend fun rename(newName: String, library: RepertoireLibrary) {
        flush()
        val renamed = withContext(writer) {
            val renamed = RepertoireLibrary.renameFiles(files.get().pgn, newName)
            // Saves queued behind the rename go to the new files.
            files.set(Files(renamed.first, renamed.second))
            renamed
        }
        entryId = renamed.second.path
        pgnFile = renamed.first
        sidecarFile = renamed.second
        name = renamed.first.nameWithoutExtension
        library.refresh()
    }

    /** Saves what is pending. */
    suspend fun close() {
        isClosed = true
        flush()
    }

    /** Stops without saving, for a repertoire whose files are being deleted: a save would
     *  recreate them. */
    fun discard() {
        isClosed = true
        isDiscarded = true
        pgnSaveJob?.cancel()
        pgnSaveJob = null
        sidecarSaveJob?.cancel()
        sidecarSaveJob = null
    }

    val color: Side get() { revision; return core.color() }
    val database: ExplorerDatabase get() { revision; return core.database() }
    val loadWarnings: List<String> get() = core.loadWarnings()

    /** The move tree, read from the core. */
    val tree: Tree get() = Tree(core, revision)
    /** Coverage values, read from the core. */
    val coverage: Coverage get() = Coverage(core, revision)
    /** Settings and cards, read from the core. */
    val sidecar: SidecarValues get() = SidecarValues(this)

    /** The cards, copied once per change. */
    val studyCards: Map<Epd, Card>
        get() {
            val revision = revision
            cachedCards?.let { (cachedRevision, cards) -> if (cachedRevision == revision) return cards }
            val cards = core.cards()
            cachedCards = revision to cards
            return cards
        }

    // MARK: Stats

    fun stats(epd: Epd): ExplorerStats? {
        // The core's cache isn't observed; reading `revision`, which stats arriving bump,
        // redraws views as soon as the stats come in.
        revision
        return core.stats(epd)
    }

    /** The opening name of a node, or of its nearest ancestor, from stats already loaded. */
    fun openingName(id: NodeId): String? {
        revision
        return core.openingName(id)
    }

    /** Fetches stats for the position on screen, ahead of the coverage check. */
    fun requestStats(epd: Epd) = core.requestStats(epd, System.currentTimeMillis())

    /** The coverage check runs while one of this repertoire's screens is showing (overview,
     *  builder, study), so the library and the other tabs never fetch. It only asks for
     *  opponent-to-move positions you would meet at least once in N games, most frequent first. */
    fun startCoverageCheck() = apply(core.startCoverageCheck())
    fun stopCoverageCheck() = core.stopCoverageCheck()

    /** Opponent positions above your target whose stats are not loaded yet. */
    val uncheckedPositions: Int get() { revision; return core.uncheckedPositions().toInt() }

    // MARK: Edits

    fun addMove(uci: String, parent: NodeId): NodeId? {
        val result = core.addMove(uci, parent)
        apply(result.changes)
        return result.node
    }

    /** Adds moves one after another; returns the last node. */
    fun addLine(ucis: List<String>, start: NodeId): NodeId? {
        val result = core.addLine(ucis, start)
        apply(result.changes)
        return result.node
    }

    fun delete(id: NodeId) = apply(core.delete(id))
    fun promote(id: NodeId) = apply(core.promote(id))
    fun setNote(text: String, id: NodeId) = apply(core.setNote(text, id))
    fun undo() = apply(core.undo())

    // MARK: Settings and training

    fun updateSettings(color: Side, database: ExplorerDatabase, targetGames: Int) =
        apply(core.updateSettings(color, database, targetGames.toLong(), nowTimestamp()))

    /** Excludes an opponent move at `node`'s position from coverage, or includes it again.
     *  Applies wherever the position occurs. */
    fun setExcluded(uci: String, node: NodeId, excluded: Boolean) =
        apply(core.setExcluded(uci, node, excluded, nowTimestamp()))

    fun isExcluded(uci: String, node: NodeId): Boolean {
        revision
        return core.isExcluded(uci, node)
    }

    fun rememberLine(ucis: List<String>) = apply(core.rememberLine(ucis))

    val revlogFile: File get() = RepertoireLibrary.revlogFile(pgnFile)

    fun learningProgress(node: NodeId = ROOT_NODE): Progress {
        revision
        return core.learningProgress(node)
    }

    /** Every move in the PGN, both sides. */
    val savedMoveCount: Int get() { revision; return core.savedMoveCount().toInt() }

    val practiceMode: PracticeMode get() { revision; return core.practiceMode() }

    val newMoveOrder: NewMoveOrder get() { revision; return core.newMoveOrder() }

    fun remainingLimits(timing: SchedTiming): RemainingLimits = core.remainingLimits(timing)

    /** Today's New / Learning / To Review counts, as on Anki's deck overview. */
    fun studyCounts(timing: SchedTiming = schedTiming()): Counts {
        revision
        return core.studyCounts(timing)
    }

    /** Anki's custom study "Increase today's new card limit". */
    fun extendNewLimitToday(count: Int, timing: SchedTiming = schedTiming()) =
        apply(core.extendLimitsToday(count.toLong(), 0, timing))

    /** Anki's custom study "Increase today's review card limit". */
    fun extendReviewLimitToday(count: Int, timing: SchedTiming = schedTiming()) =
        apply(core.extendLimitsToday(0, count.toLong(), timing))

    /** Reviews due today beyond today's review limit. */
    fun reviewsBeyondLimit(timing: SchedTiming = schedTiming()): Int {
        revision
        return core.reviewsBeyondLimit(timing).toInt()
    }

    /** Daily limits ("This deck"), practice mode and new move order for this repertoire. */
    fun updateStudySettings(limits: DeckLimits, practiceMode: PracticeMode?, newMoveOrder: NewMoveOrder?) =
        apply(core.updateStudySettings(limits, practiceMode, newMoveOrder, nowTimestamp()))

    /** Your-turn positions under `node` where cards are asked. */
    fun cardEpds(node: NodeId = ROOT_NODE): Set<Epd> {
        revision
        return core.cardEpds(node).toSet()
    }

    fun cardNodes(node: NodeId = ROOT_NODE): List<NodeId> {
        revision
        return core.cardNodes(node)
    }

    fun suspendedCardEpds(node: NodeId = ROOT_NODE): Set<Epd> {
        revision
        return core.suspendedCardEpds(node).toSet()
    }

    fun openingBranches(): List<NodeId> = core.openingBranches()

    /** How often each node is reached. */
    val reach: Map<NodeId, Double> get() { revision; return core.reach() }

    /** The whole review log, including answers not written yet. Read off the main thread. */
    suspend fun reviewLog(): List<RevlogEntry> = readRevlog { core.reviewLog(it) }

    /** This repertoire's part of the statistics; see `RepertoireDoc.graphParts`. */
    suspend fun graphParts(wholeCollection: Boolean): GraphParts =
        readRevlog { core.graphParts(it, wholeCollection) }

    private suspend fun <T> readRevlog(body: (ByteArray) -> T): T {
        val revlog = files.get().revlog
        return withContext(Dispatchers.IO) {
            body(runCatching { FileAccess.read(revlog) }.getOrDefault(ByteArray(0)))
        }
    }

    // MARK: Saving

    /** Writes pending changes now (on close, when the app goes to the background or quits).
     *  Saves already running finish first: the writer runs one at a time, and these find
     *  nothing left when they had it all. */
    suspend fun flush() {
        pgnSaveJob?.cancel()
        pgnSaveJob = null
        sidecarSaveJob?.cancel()
        sidecarSaveJob = null
        savePgn()
        saveSidecar()
    }

    fun dismissSaveError() {
        saveError = null
    }

    private fun schedulePgnSave(ms: Long) {
        if (isClosed) return
        pgnSaveJob?.cancel()
        pgnSaveJob = scope.launch {
            delay(ms)
            pgnSaveJob = null
            savePgn()
        }
    }

    private fun scheduleSidecarSave(ms: Long) {
        if (isClosed) return
        sidecarSaveJob?.cancel()
        sidecarSaveJob = scope.launch {
            if (ms > 0) delay(ms)
            sidecarSaveJob = null
            saveSidecar()
        }
    }

    private suspend fun savePgn() {
        if (isDiscarded) return
        try {
            withContext(writer) { if (!isDiscarded) savePgn(core, files.get().pgn) }
            saveError = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            saveError = "Could not save ${pgnFile.name}: ${e.message}"
        }
    }

    private fun savePgn(core: RepertoireDoc, file: File) {
        val text = core.pgnToSave() ?: return
        FileAccess.write(text.toByteArray(), file)
        core.pgnSaved(text)
    }

    /** Appends new answers to the review log, then writes the sidecar. */
    private suspend fun saveSidecar() {
        if (isDiscarded) return
        try {
            withContext(writer) {
                if (isDiscarded) return@withContext
                val current = files.get()
                core.revlogToAppend()?.let { lines ->
                    try {
                        FileAccess.append(lines, current.revlog)
                    } catch (e: IOException) {
                        throw SaveException("Could not save the review log: ${e.message}")
                    }
                    core.revlogAppended()
                }
                val data = core.sidecarToSave(schedTiming()) ?: return@withContext
                FileAccess.write(data, current.sidecar)
                core.sidecarSaved(data)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: SaveException) {
            saveError = e.message
        } catch (e: Exception) {
            saveError = "Could not save training data: ${e.message}"
        }
    }

    private class SaveException(message: String) : Exception(message)

    // MARK: Changes from elsewhere

    /**
     * Another device's versions of the files, from the sync (iCloud's file presenters on
     * Apple). Each is written over the local file, as iCloud would, then handed to the core
     * to merge (`remotePgn`, `remoteSidecar`), which asks for a save when the merge kept
     * something the file lacks; the review logs are merged as files (the union by entry id).
     * Runs on the writer, so it never overlaps one of our own saves.
     *
     * `written`: the files already hold `pgn` and `sidecar` (the desktop's folder, changed by the
     * provider's client), so they are not written again.
     */
    suspend fun applyRemote(
        pgn: ByteArray? = null,
        sidecar: ByteArray? = null,
        revlog: ByteArray? = null,
        written: Boolean = false,
    ) {
        if (isClosed) return
        val changes = withContext(writer) {
            if (isDiscarded) return@withContext emptyList()
            val current = files.get()
            val changes = mutableListOf<Changes>()
            if (pgn != null) {
                if (!written) FileAccess.write(pgn, current.pgn)
                changes += core.remotePgn(pgn.toString(Charsets.UTF_8))
            }
            if (sidecar != null) {
                if (!written) FileAccess.write(sidecar, current.sidecar)
                changes += core.remoteSidecar(sidecar)
            }
            if (revlog != null) {
                val local = runCatching { FileAccess.read(current.revlog) }.getOrNull()
                FileAccess.write(if (local == null) revlog else mergeRevlogData(local, revlog), current.revlog)
            }
            changes
        }
        for (c in changes) apply(c)
    }

    /**
     * A provider's conflict copies of the files (Dropbox's "conflicted copy", on the desktop):
     * merged in, never lost, as iCloud's conflict versions on Apple (`mergeConflictVersion`,
     * `mergeSidecarData`, the review logs' union). The core asks to save what the PGN's copy
     * added. On the writer, like [applyRemote].
     */
    suspend fun mergeConflictCopy(pgn: ByteArray? = null, sidecar: ByteArray? = null, revlog: ByteArray? = null) {
        if (isClosed) return
        val changes = withContext(writer) {
            val current = files.get()
            val changes = mutableListOf<Changes>()
            if (pgn != null) changes += core.mergeConflictVersion(pgn.toString(Charsets.UTF_8))
            if (sidecar != null) {
                // Merged as files first (the core saves only what a remote sidecar lacks), then
                // into what is open.
                val local = runCatching { FileAccess.read(current.sidecar) }.getOrNull()
                val merged = if (local == null) sidecar else mergeSidecarData(local, sidecar)
                if (merged != null) {
                    FileAccess.write(merged, current.sidecar)
                    changes += core.remoteSidecar(merged)
                }
            }
            if (revlog != null) {
                val local = runCatching { FileAccess.read(current.revlog) }.getOrNull()
                FileAccess.write(if (local == null) revlog else mergeRevlogData(local, revlog), current.revlog)
            }
            changes
        }
        for (c in changes) apply(c)
    }

    /** Someone else renamed the PGN within the folder (the sync): the sidecar and the review
     *  log follow it (the library pairs them by name). */
    suspend fun renamedRemotely(newPgn: File) {
        if (isClosed || newPgn.canonicalPath == pgnFile.canonicalPath) return
        val oldId = entryId
        val oldPgn = pgnFile
        val newSidecar = RepertoireLibrary.sidecarFile(newPgn)
        files.set(Files(newPgn, newSidecar))
        pgnFile = newPgn
        sidecarFile = newSidecar
        name = newPgn.nameWithoutExtension
        entryId = newSidecar.path
        withContext(writer) { RepertoireLibrary.moveCompanions(oldPgn, newPgn) }
        onRenamed?.invoke(oldId)
    }

    /** Someone else deleted the PGN (the sync): the repertoire is gone from here. */
    /**
     * The sync is deleting the repertoire: closed and discarded, and back once no save of it is
     * still running, so none writes a file again after it is deleted.
     */
    suspend fun removedRemotely() {
        if (isClosed) return
        discard()
        onRemoved?.invoke()
        withContext(writer) {}
    }

    /** The files, read by the writer when each operation runs. */
    private data class Files(val pgn: File, val sidecar: File) {
        val revlog: File get() = RepertoireLibrary.revlogFile(pgn)
    }

    /** Changes the core made by itself (stats arriving), from any thread. */
    private class Listener(document: RepertoireDocument) : DocumentListener {
        private val document = WeakReference(document)
        override fun changed(changes: Changes) {
            val document = document.get() ?: return
            document.scope.launch { document.apply(changes) }
        }
    }

    // MARK: Read-only views of the core's state

    /** The move tree. Reading through the document registers the view for its changes. */
    class Tree(val core: RepertoireDoc, val revision: ULong) {
        operator fun get(id: NodeId): Node? = core.node(id)
        val root: Node get() = core.root()
        val count: Int get() = core.count().toInt()
        val nodes: List<Node> get() = core.allNodes()

        fun childByUci(id: NodeId, uci: String): NodeId? = core.childByUci(id, uci)
        fun childBySan(id: NodeId, san: String): NodeId? = core.childBySan(id, san)
        fun path(id: NodeId): List<NodeId> = core.path(id)
        fun moves(id: NodeId): List<PlayedMove> = core.moves(id)
        fun subtree(id: NodeId): List<NodeId> = core.subtree(id)
        fun leaves(id: NodeId): List<NodeId> = core.leaves(id)
        fun isAncestor(a: NodeId, b: NodeId): Boolean = core.isAncestor(a, b)
        fun transpositionTarget(id: NodeId): NodeId? = core.transpositionTarget(id)
        fun nodesAt(epd: Epd): List<NodeId> = core.nodesAt(epd)
        fun nodeFollowing(ucis: List<String>, start: NodeId = ROOT_NODE): NodeId? = core.nodeFollowing(ucis, start)
        fun position(id: NodeId): Position? = core.position(id)
        /** SAN line to a node, e.g. "1. e4 c5 2. Nf3". */
        fun lineText(id: NodeId): String = core.lineText(id)
    }

    class Coverage(val core: RepertoireDoc, val revision: ULong) {
        operator fun get(id: NodeId): NodeCoverage? = core.coverage(id)
        val root: NodeCoverage? get() = core.coverageRoot()
        /** All gaps, biggest first. */
        fun gaps(): List<CoverageGap> = core.gaps()
        /** Replies at a position that is not in the repertoire (a draft on the board). */
        fun replies(epd: Epd, reach: Double?): List<ReplyInfo>? = core.draftReplies(epd, reach)
    }

    class SidecarValues(val document: RepertoireDocument) {
        val studyCards: Map<Epd, Card> get() = document.studyCards
        val color: Side get() = document.color
        val database: ExplorerDatabase get() = document.database
        val targetGames: Int get() { document.revision; return document.core.targetGames().toInt() }
        val limits: DeckLimits? get() { document.revision; return document.core.limits() }
        val practiceMode: PracticeMode? get() { document.revision; return document.core.ownPracticeMode() }
        val newMoveOrder: NewMoveOrder? get() { document.revision; return document.core.ownNewMoveOrder() }
        val lastLine: List<String>? get() = document.core.lastLine()

        /** When the next card falls due after today's are done (unix seconds). */
        fun nextDue(timing: SchedTiming): Long? {
            document.revision
            return document.core.nextDue(timing)
        }

        /** Unix seconds. */
        fun laterLearningDues(timing: SchedTiming): List<Long> {
            document.revision
            return document.core.laterLearningDues(timing)
        }

        fun dueTomorrow(timing: SchedTiming): Int {
            document.revision
            return document.core.dueTomorrow(timing).toInt()
        }
    }
}
