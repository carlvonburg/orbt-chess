package org.orbtchess.orbt.storage

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import org.orbtchess.orbt.core.FileKind
import org.orbtchess.orbt.core.mergeRevlogData
import org.orbtchess.orbt.core.mergeSidecarData
import org.orbtchess.orbt.core.syncFileKind
import java.io.File
import java.nio.file.FileSystems
import java.nio.file.StandardWatchEventKinds
import java.nio.file.WatchService
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.logging.Logger

/**
 * The desktop's repertoire folder, which the user may keep inside Dropbox or Google Drive for
 * desktop: the provider's client changes it (other devices' edits, deletes, conflict copies),
 * and this hands those changes to the library and the open documents, as `SyncService` does on
 * Android with what it downloads.
 *
 * The folder's files (not its subfolders: the sync's files are at the top) are listed every
 * [interval], sooner when Java's `WatchService` reports something (it polls on macOS and may say
 * nothing on Google Drive's virtual drive on Windows, hence the listing). A change counts once
 * the file has stayed the same for [settle], so a file the client is still writing is not read
 * half-way; and only when its content differs from what we last read or wrote
 * (`FileAccess.watcher`), so our own saves never come back as remote changes.
 *
 * - A changed PGN or sidecar of an open repertoire goes to its document (`applyRemote`), which
 *   merges it into what is on screen; a review log is merged with the one we last knew (the
 *   union by id: answers are never lost when another device's version replaced ours).
 * - A deleted PGN closes its document.
 * - A conflict copy ([conflictCopies]: the core's rule) is merged into its original with the core's merges
 *   (the PGN through its document, opened for the moment when needed; the sidecar with
 *   `mergeSidecarData`, the review log with `mergeRevlogData`), then removed. The library never
 *   lists them ([RepertoireLibrary.hidden]).
 *
 * `run` runs on the main thread (the documents' scope) until cancelled; the listing runs on
 * `Dispatchers.IO`. It follows the library to another folder ([RepertoireLibrary.switchTo]).
 */
class FolderWatcher(
    private val documents: Documents,
    private val interval: Long = 2_000,
    private val settle: Long = 1_000,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val library get() = documents.library

    /** What we last read or wrote of a file. */
    private class Known(val size: Long, val modified: Long, val data: ByteArray?)

    /** A file seen changing (`size` -1: gone), since `since`. */
    private class Pending(val size: Long, val modified: Long, val since: Long)

    /** A file changed by someone else; `previous` is what we knew of it. */
    internal sealed class Change(val name: String) {
        /** `original`: set when this is a conflict copy of that file. */
        class Changed(name: String, val data: ByteArray, val previous: ByteArray?, val original: String? = null) : Change(name)
        class Deleted(name: String) : Change(name)
    }

    @Volatile private var folder: File? = null
    /** By file name, for [folder]; written by our own saves on any thread. */
    private val known = ConcurrentHashMap<String, Known>()
    /** Only touched by the listing, one at a time. */
    private val pending = HashMap<String, Pending>()
    private var watchService: WatchService? = null

    init {
        library.hidden = { isConflictCopy(library.folder, it) }
    }

    /** Watches until cancelled. */
    suspend fun run() {
        FileAccess.watcher = observer
        try {
            while (currentCoroutineContext().isActive) {
                try {
                    check()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    log.warning("folder change: ${e.message}")
                }
                waitForChange()
            }
        } finally {
            if (FileAccess.watcher === observer) FileAccess.watcher = null
            withContext(Dispatchers.IO) { watchService?.close() }
            watchService = null
        }
    }

    /** Lists the folder once and applies what changed (`run` does this in a loop; tests call it). */
    internal suspend fun check() {
        val folder = library.folder.absoluteFile
        val changes = withContext(Dispatchers.IO) {
            if (folder != this@FolderWatcher.folder) start(folder) else scan(folder)
        }
        if (changes.isNotEmpty()) handle(folder, changes)
    }

    /** Our own writes, from `FileAccess`. */
    internal val observer: (File, ByteArray?) -> Unit = ::ownChange

    private fun ownChange(file: File, data: ByteArray?) {
        if (file.absoluteFile.parentFile != folder) return
        if (data == null) {
            known.remove(file.name)
        } else {
            known[file.name] = Known(file.length(), file.lastModified(), data)
        }
    }

    private suspend fun waitForChange() {
        val wait = if (pending.isEmpty()) interval else minOf(interval, settle / 2).coerceAtLeast(50)
        val service = watchService
        if (service == null) {
            delay(wait)
            return
        }
        runInterruptible(Dispatchers.IO) {
            val key = service.poll(wait, TimeUnit.MILLISECONDS) ?: return@runInterruptible
            key.pollEvents()
            key.reset()
        }
    }

    /** A new folder: what is there now is known, except conflict copies left from before. */
    private fun start(folder: File): List<Change> {
        watchService?.close()
        watchService = null
        known.clear()
        pending.clear()
        this.folder = folder
        val copies = mutableListOf<Change>()
        val files = files(folder)
        val pairs = conflictCopies(files.map { it.name })
        for (file in files) {
            val data = runCatching { FileAccess.read(file) }.getOrNull()
            val original = pairs[file.name]
            if (original != null) {
                if (data != null) copies += Change.Changed(file.name, data, null, original)
            } else {
                known[file.name] = Known(file.length(), file.lastModified(), data)
            }
        }
        watchService = runCatching {
            FileSystems.getDefault().newWatchService().also { service ->
                folder.toPath().register(
                    service,
                    StandardWatchEventKinds.ENTRY_CREATE,
                    StandardWatchEventKinds.ENTRY_MODIFY,
                    StandardWatchEventKinds.ENTRY_DELETE,
                )
            }
        }.getOrNull()
        return copies
    }

    private fun scan(folder: File): List<Change> {
        val now = clock()
        val changes = mutableListOf<Change>()
        val present = HashSet<String>()
        val files = files(folder)
        val pairs = conflictCopies(files.map { it.name })
        for (file in files) {
            val name = file.name
            present += name
            val size = file.length()
            val modified = file.lastModified()
            val previous = known[name]
            if (previous != null && previous.size == size && previous.modified == modified) {
                pending.remove(name)
                continue
            }
            if (!settled(name, size, modified, now)) continue
            val data = runCatching { FileAccess.read(file) }.getOrNull() ?: continue
            pending.remove(name)
            // Our own save, or the same bytes written again.
            val latest = known[name]
            known[name] = Known(size, modified, data)
            if (latest?.data != null && latest.data.contentEquals(data)) continue
            changes += Change.Changed(name, data, latest?.data, pairs[name])
        }
        for (name in known.keys.toList()) {
            if (name in present) continue
            if (!settled(name, -1, 0, now)) continue
            pending.remove(name)
            if (File(folder, name).exists()) continue
            known.remove(name)
            changes += Change.Deleted(name)
        }
        // Gone again before settling, or written by us meanwhile.
        pending.keys.retainAll { it in present || known.containsKey(it) }
        return changes
    }

    /** Whether a file has looked like this for [settle]. */
    private fun settled(name: String, size: Long, modified: Long, now: Long): Boolean {
        val seen = pending[name]
        if (seen == null || seen.size != size || seen.modified != modified) {
            pending[name] = Pending(size, modified, now)
            return settle <= 0
        }
        return now - seen.since >= settle
    }

    private fun files(folder: File): List<File> =
        folder.listFiles().orEmpty().filter { file ->
            file.isFile && !file.name.startsWith(".") &&
                (conflictCopyOriginal(file.name) != null || syncFileKind(file.name) != null)
        }

    // MARK: Applying

    private suspend fun handle(folder: File, changes: List<Change>) {
        class Remote(var pgn: ByteArray? = null, var sidecar: ByteArray? = null, var revlog: ByteArray? = null)
        val open = LinkedHashMap<RepertoireDocument, Remote>()
        val copies = mutableListOf<Change.Changed>()
        for (change in changes) {
            if (change is Change.Changed && change.original != null) {
                copies += change
                continue
            }
            val document = documentOf(change.name)
            when (change) {
                is Change.Deleted -> if (document?.pgnFile?.name == change.name) document.removedRemotely()
                is Change.Changed -> {
                    val kind = syncFileKind(change.name)
                    if (document != null) {
                        val remote = open.getOrPut(document) { Remote() }
                        when (kind) {
                            FileKind.PGN -> remote.pgn = change.data
                            FileKind.SIDECAR -> remote.sidecar = change.data
                            // Merged with the file now on disk: what we had written stays.
                            FileKind.REVLOG -> remote.revlog = change.previous
                            null -> {}
                        }
                    } else if (kind == FileKind.REVLOG && change.previous != null) {
                        val merged = mergeRevlogData(change.data, change.previous)
                        if (!merged.contentEquals(change.data)) {
                            withContext(Dispatchers.IO) { FileAccess.write(merged, File(folder, change.name)) }
                        }
                    }
                }
            }
        }
        for ((document, remote) in open) document.applyRemote(remote.pgn, remote.sidecar, remote.revlog, written = true)
        if (copies.isNotEmpty()) {
            library.refresh()
            for (copy in copies) mergeCopy(folder, copy)
        }
        library.refresh()
    }

    /** Merges a conflict copy into its original, then removes it. */
    private suspend fun mergeCopy(folder: File, copy: Change.Changed) {
        val originalName = copy.original ?: return
        val original = File(folder, originalName)
        val copyFile = File(folder, copy.name)
        val kind = syncFileKind(originalName) ?: return
        if (!withContext(Dispatchers.IO) { original.exists() }) {
            // Only the copy is left (the original was deleted or renamed): it takes its place.
            withContext(Dispatchers.IO) { runCatching { FileAccess.move(copyFile, original) } }
            return
        }
        val document = documentOf(originalName)
        when (kind) {
            FileKind.PGN -> {
                if (document != null) {
                    document.mergeConflictCopy(pgn = copy.data)
                } else {
                    // Merged through the core's tree, so the repertoire opens for a moment.
                    val entry = library.entries.firstOrNull { it.pgnFile.name == originalName }
                    if (entry == null || entry.needsSetup) {
                        log.warning("conflict copy ${copy.name}: ${originalName} is not set up, left as it is")
                        return
                    }
                    val opened = documents.open(entry) ?: return
                    opened.mergeConflictCopy(pgn = copy.data)
                    opened.flush()
                    documents.close(entry.id)
                }
            }
            FileKind.SIDECAR -> {
                if (document != null) {
                    document.mergeConflictCopy(sidecar = copy.data)
                } else {
                    val merged = withContext(Dispatchers.IO) {
                        mergeSidecarData(FileAccess.read(original), copy.data)?.also { FileAccess.write(it, original) }
                    }
                    if (merged == null) return
                }
            }
            FileKind.REVLOG -> {
                if (document != null) {
                    document.mergeConflictCopy(revlog = copy.data)
                } else {
                    withContext(Dispatchers.IO) { FileAccess.write(mergeRevlogData(FileAccess.read(original), copy.data), original) }
                }
            }
        }
        withContext(Dispatchers.IO) { runCatching { FileAccess.delete(copyFile) } }
    }

    private fun documentOf(name: String): RepertoireDocument? = documents.documents.values.firstOrNull {
        it.pgnFile.name == name || it.sidecarFile.name == name || it.revlogFile.name == name
    }

    companion object {
        private val log = Logger.getLogger("org.orbtchess.orbt.storage")
    }
}
