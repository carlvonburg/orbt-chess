package org.orbtchess.orbt.storage

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.orbtchess.orbt.core.LibrarySidecar
import org.orbtchess.orbt.core.librarySidecar
import org.orbtchess.orbt.core.newRepertoirePgn
import org.orbtchess.orbt.core.revlogExtension
import org.orbtchess.orbt.core.sidecarExtension
import java.io.File
import java.io.IOException
import java.text.BreakIterator
import java.text.Collator

class RepertoireEntry(
    /** Path of the sidecar, stable across launches. */
    val id: String,
    val name: String,
    val pgnFile: File,
    val sidecarFile: File,
    /** The sidecar file's bytes; null when a PGN was dropped into the folder and has not been
     *  set up yet. */
    val sidecarData: ByteArray?,
    /** The sidecar, read by the core, for the library row. */
    val sidecar: LibrarySidecar?,
) {
    val needsSetup: Boolean get() = sidecar == null

    override fun equals(other: Any?): Boolean =
        other is RepertoireEntry && id == other.id && name == other.name && pgnFile == other.pgnFile &&
            sidecarFile == other.sidecarFile && sidecarData.contentEquals(other.sidecarData)

    override fun hashCode(): Int = id.hashCode()
}

/** Why a library operation failed. */
class RepertoireFileException(val reason: Reason) : IOException(reason.message) {
    enum class Reason(val message: String) {
        INVALID_NAME("The name has no letters or digits."),
        EXISTS("A repertoire with this name already exists."),
    }
}

/**
 * The repertoires in the app's folder (`AppFolders.repertoires`): `<Name>.pgn`, its sidecar
 * `<Name>.otrep.json` and its review log `<Name>.otlog.jsonl`. Imported PGNs are copied into
 * this folder. No folder watching here (iCloud's file presenters on Apple): the app calls
 * `refresh` when it comes back to the foreground, the sync after it downloads, and the
 * desktop's `FolderWatcher` when the provider's client changes the folder.
 *
 * Main-thread confined like the Swift `@MainActor` model: `scope` runs on the main thread
 * (e.g. `MainScope()`); scans and writes run on `Dispatchers.IO`.
 */
class RepertoireLibrary(folder: File, private val scope: CoroutineScope) {
    val folder: File = folder

    /**
     * PGN names the scan leaves out: on the desktop, the conflict copies Dropbox and Google
     * Drive make, which are merged into their repertoire and removed (`FolderWatcher`).
     */
    @Volatile var hidden: (String) -> Boolean = { false }

    var entries: List<RepertoireEntry> by mutableStateOf(emptyList())
        private set
    var isLoaded: Boolean by mutableStateOf(false)
        private set
    var lastError: String? by mutableStateOf(null)

    private var scheduledRefresh: Job? = null
    private var scanGeneration = 0

    suspend fun setUp() {
        if (isLoaded) return
        withContext(Dispatchers.IO) { folder.mkdirs() }
        refresh()
        isLoaded = true
    }

    /** Rescans soon, so bursts of changes become one scan. */
    fun scheduleRefresh() {
        scheduledRefresh?.cancel()
        scheduledRefresh = scope.launch {
            delay(1_000)
            refresh()
        }
    }

    /** Rescans the folder off the main thread. */
    suspend fun refresh() {
        scanGeneration += 1
        val generation = scanGeneration
        val folder = folder
        val hidden = hidden
        val result = withContext(Dispatchers.IO) { scan(folder, hidden) }
        // A later scan started meanwhile and has fresher results.
        if (generation != scanGeneration) return
        if (result != entries) entries = result
    }

    /** Puts the entry for a file the app just wrote in the list right away; a scan follows. */
    private fun insertEntry(pgn: File): RepertoireEntry {
        val entry = entry(pgn)
        entries = (entries.filter { it.id != entry.id } + entry).sortedWith(byName)
        scheduleRefresh()
        return entry
    }

    fun entry(id: String): RepertoireEntry? = entries.firstOrNull { it.id == id }

    /** Creates `<name>.pgn` and its sidecar (bytes from `newSidecar`) in the repertoire folder. */
    suspend fun create(name: String, sidecar: ByteArray): RepertoireEntry =
        add(name, { newRepertoirePgn(it).toByteArray() }, sidecar)

    /** Adds a picked PGN as `<name>.pgn`, with its sidecar. Nothing is written until the user
     *  has set it up, so cancelling leaves no file behind. */
    suspend fun importPgn(data: ByteArray, name: String, sidecar: ByteArray): RepertoireEntry =
        add(name, { data }, sidecar)

    private suspend fun add(name: String, pgn: (String) -> ByteArray, sidecar: ByteArray): RepertoireEntry {
        val clean = cleanName(name)
        if (clean.isEmpty()) throw RepertoireFileException(RepertoireFileException.Reason.INVALID_NAME)
        val file = File(folder, "$clean.pgn")
        withContext(Dispatchers.IO) {
            if (file.exists() || sidecarFile(file).exists()) {
                throw RepertoireFileException(RepertoireFileException.Reason.EXISTS)
            }
            FileAccess.write(pgn(clean), file)
            FileAccess.write(sidecar, sidecarFile(file))
        }
        return insertEntry(file)
    }

    /** Writes a sidecar for a PGN that was imported or dropped into the folder. */
    suspend fun saveSidecar(sidecar: ByteArray, entry: RepertoireEntry) {
        withContext(Dispatchers.IO) { FileAccess.write(sidecar, entry.sidecarFile) }
        insertEntry(entry.pgnFile)
    }

    /** Deletes a repertoire from the folder (PGN, sidecar and review log). */
    suspend fun delete(entry: RepertoireEntry) {
        withContext(Dispatchers.IO) {
            FileAccess.delete(entry.pgnFile)
            runCatching { FileAccess.delete(entry.sidecarFile) }
            runCatching { FileAccess.delete(revlogFile(entry.pgnFile)) }
        }
        entries = entries.filter { it.id != entry.id }
        scheduleRefresh()
    }

    /** A picked PGN's bytes and a name for it. */
    class ImportedFile(val data: ByteArray, val name: String)

    companion object {
        val SIDECAR_EXTENSION: String = sidecarExtension()
        val REVLOG_EXTENSION: String = revlogExtension()

        fun sidecarFile(pgn: File): File = File(pgn.parentFile, "${pgn.nameWithoutExtension}.$SIDECAR_EXTENSION")

        /** The review log next to a PGN. */
        fun revlogFile(pgn: File): File = File(pgn.parentFile, "${pgn.nameWithoutExtension}.$REVLOG_EXTENSION")

        /** A picked file's name as a repertoire name ("Imported" when nothing is left). */
        fun importName(fileName: String): String =
            cleanName(fileName.removeSuffix(".pgn").removeSuffix(".PGN")).ifEmpty { "Imported" }

        /**
         * Renames a repertoire's PGN, sidecar and review log to `<name>.pgn`, `<name>.otrep.json`
         * and `<name>.otlog.jsonl`. Blocking; returns the new PGN and sidecar.
         */
        fun renameFiles(pgn: File, name: String): Pair<File, File> {
            val clean = cleanName(name)
            if (clean.isEmpty()) throw RepertoireFileException(RepertoireFileException.Reason.INVALID_NAME)
            val newPgn = File(pgn.parentFile, "$clean.pgn")
            val sidecar = sidecarFile(pgn)
            val newSidecar = sidecarFile(newPgn)
            // A case-only rename points at the same file on a case-insensitive volume.
            val sameFile = newPgn.path.lowercase() == pgn.path.lowercase()
            if (!sameFile && (newPgn.exists() || newSidecar.exists())) {
                throw RepertoireFileException(RepertoireFileException.Reason.EXISTS)
            }
            // As written: File equality ignores case on Windows.
            if (newPgn.path != pgn.path) {
                FileAccess.move(pgn, newPgn)
                try {
                    FileAccess.move(sidecar, newSidecar)
                } catch (e: IOException) {
                    runCatching { FileAccess.move(newPgn, pgn) }
                    throw e
                }
                val revlog = revlogFile(pgn)
                if (revlog.exists()) runCatching { FileAccess.move(revlog, revlogFile(newPgn)) }
            }
            return newPgn to newSidecar
        }

        /** After someone else renamed a PGN from `old` to `new`, moves its sidecar and review
         *  log along, unless a file already has the new name. */
        fun moveCompanions(old: File, new: File) {
            for ((from, to) in listOf(sidecarFile(old) to sidecarFile(new), revlogFile(old) to revlogFile(new))) {
                if (!from.exists() || to.exists()) continue
                runCatching { FileAccess.move(from, to) }
            }
        }

        private fun scan(folder: File, hidden: (String) -> Boolean): List<RepertoireEntry> =
            folder.walkTopDown()
                .onEnter { it == folder || !it.name.startsWith(".") }
                .filter { it.isFile && it.name.endsWith(".pgn") && !it.name.startsWith(".") && !hidden(it.name) }
                .map { entry(it) }
                .sortedWith(byName)
                .toList()

        private fun entry(pgn: File): RepertoireEntry {
            val sidecarFile = sidecarFile(pgn)
            val data = runCatching { FileAccess.read(sidecarFile) }.getOrNull()
            val sidecar = data?.let { librarySidecar(it) }
            return RepertoireEntry(
                id = sidecarFile.path, name = pgn.nameWithoutExtension, pgnFile = pgn, sidecarFile = sidecarFile,
                sidecarData = if (sidecar == null) null else data, sidecar = sidecar,
            )
        }

        /** Finder's order (`localizedStandardCompare`): case-insensitive, numbers by value. */
        private val byName: Comparator<RepertoireEntry> = Comparator { a, b -> standardCompare(a.name, b.name) }

        private val collator: Collator = Collator.getInstance().apply { strength = Collator.SECONDARY }

        private fun standardCompare(a: String, b: String): Int {
            val chunk = Regex("\\d+|\\D+")
            val left = chunk.findAll(a).map { it.value }.toList()
            val right = chunk.findAll(b).map { it.value }.toList()
            for (i in 0 until minOf(left.size, right.size)) {
                val x = left[i]
                val y = right[i]
                val result = if (x[0].isDigit() && y[0].isDigit()) {
                    x.trimStart('0').length.compareTo(y.trimStart('0').length)
                        .takeIf { it != 0 } ?: x.trimStart('0').compareTo(y.trimStart('0'))
                } else {
                    collator.compare(x, y)
                }
                if (result != 0) return result
            }
            return left.size.compareTo(right.size).takeIf { it != 0 } ?: a.compareTo(b)
        }

        /** The name as a file name: safe characters only, single spaces, no leading dot, at
         *  most 100 characters. */
        fun cleanName(name: String): String {
            val words = safeRepertoireName(name).split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
            return graphemes(words.trimStart('.', ' ')).take(100).joinToString("").trim()
        }

        /**
         * Keeps letters and digits of any script, spaces, and - _ . , ( ) ' & + !
         * Path separators become "-" (":" becomes " -", as in "Ruy Lopez - Berlin"); emoji and
         * other symbols that cause trouble in file names (on Windows, Android or in sync) are removed.
         */
        fun safeRepertoireName(name: String): String = buildString {
            for (c in graphemes(name)) {
                when {
                    c == ":" -> append(" -")
                    c == "/" || c == "\\" -> append("-")
                    c.length == 1 && c[0] in "-_.,()'&+! " -> append(c)
                    c.codePoints().allMatch(::isNameCodePoint) -> append(c)
                }
            }
        }

        private fun isNameCodePoint(cp: Int): Boolean = when (Character.getType(cp).toByte()) {
            Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
            Character.MODIFIER_LETTER, Character.OTHER_LETTER, Character.DECIMAL_DIGIT_NUMBER,
            Character.LETTER_NUMBER, Character.OTHER_NUMBER, Character.COMBINING_SPACING_MARK -> true
            // Accents, but not the emoji variation selector.
            Character.NON_SPACING_MARK -> cp != 0xFE0F
            else -> false
        }

        /** User-perceived characters, as Swift's `Character`. */
        private fun graphemes(text: String): List<String> {
            val iterator = BreakIterator.getCharacterInstance().apply { setText(text) }
            val result = mutableListOf<String>()
            var start = iterator.first()
            var end = iterator.next()
            while (end != BreakIterator.DONE) {
                result += text.substring(start, end)
                start = end
                end = iterator.next()
            }
            return result
        }
    }
}
