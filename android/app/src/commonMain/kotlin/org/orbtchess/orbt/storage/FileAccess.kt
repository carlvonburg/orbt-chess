package org.orbtchess.orbt.storage

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Reads and writes of the repertoire files (`apple/ORBT/Storage/FileAccess.swift` without the
 * file coordination: no iCloud here; on the desktop the provider's client may change the folder,
 * `FolderWatcher` tells the app). Blocking: call from a background dispatcher, never the main
 * thread.
 */
object FileAccess {
    /**
     * Told after every file this package writes, appends to, moves or deletes (`data` null:
     * deleted), with the file's whole contents; called on the IO thread. For the sync
     * (`RepertoireSync.localChanged`).
     */
    @Volatile var observer: ((file: File, data: ByteArray?) -> Unit)? = null
    /** Told the same as [observer]: the desktop's folder watcher, so our own saves don't come
     *  back as changes from elsewhere. */
    @Volatile var watcher: ((file: File, data: ByteArray?) -> Unit)? = null

    /**
     * Where in-place saves keep their journal, or null to replace files by renaming (Android).
     * The desktop's folder is synced by Dropbox or Google Drive for desktop, and Drive gives a
     * renamed-over file a new id (its other devices see a delete and a new file), so there
     * `write` overwrites the file's content; see [writeInPlace]. A local folder, never synced.
     */
    @Volatile var journal: File? = null

    private fun changed(file: File, data: ByteArray?) {
        observer?.invoke(file, data)
        watcher?.invoke(file, data)
    }

    fun read(file: File): ByteArray = file.readBytes()

    /** Writes a temporary file next to `file`, then renames it over `file`, so a reader never
     *  sees half a file and a crash leaves the old one; in place with a [journal]. */
    fun write(data: ByteArray, file: File) {
        file.parentFile?.mkdirs()
        val journal = journal
        if (journal != null) {
            writeInPlace(data, file, journal)
            changed(file, data)
            return
        }
        val temp = File(file.parentFile, ".${file.name}.${System.nanoTime()}.tmp")
        try {
            FileOutputStream(temp).use { out ->
                out.write(data)
                out.fd.sync()
            }
            try {
                Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            temp.delete()
        }
        changed(file, data)
    }

    /**
     * Overwrites `file`'s content, keeping the file itself (its id at the provider). Crash-safe
     * through a journal: the new content goes to `<journal>/<n>.journal` first (written, synced,
     * then renamed into place, so a journal is always whole), then over the file (synced, then
     * truncated), then the journal is removed. A crash midway leaves a journal, which
     * [recoverJournal] writes again at the next launch. A reader (the provider's client) may
     * still see a half-written file for a moment; it uploads the whole one once it settles.
     */
    private fun writeInPlace(data: ByteArray, file: File, journal: File) {
        journal.mkdirs()
        val name = "${System.nanoTime()}-${Thread.currentThread().id}"
        val temp = File(journal, "$name.tmp")
        val entry = File(journal, "$name.journal")
        FileOutputStream(temp).use { out ->
            out.write(file.absolutePath.toByteArray())
            out.write('\n'.code)
            out.write(data)
            out.fd.sync()
        }
        Files.move(temp.toPath(), entry.toPath(), StandardCopyOption.ATOMIC_MOVE)
        overwrite(data, file)
        entry.delete()
    }

    private fun overwrite(data: ByteArray, file: File) {
        RandomAccessFile(file, "rw").use { out ->
            out.seek(0)
            out.write(data)
            out.setLength(data.size.toLong())
            out.fd.sync()
        }
    }

    /** At launch, before anything reads the files: finishes the in-place writes a crash
     *  interrupted (see [writeInPlace]). Returns the files written. */
    fun recoverJournal(journal: File): List<File> {
        val entries = journal.listFiles().orEmpty().sortedBy { it.name }
        val recovered = mutableListOf<File>()
        for (entry in entries) {
            if (entry.name.endsWith(".journal")) {
                val bytes = runCatching { entry.readBytes() }.getOrNull()
                val newline = bytes?.indexOf('\n'.code.toByte()) ?: -1
                if (bytes != null && newline > 0) {
                    val file = File(bytes.copyOfRange(0, newline).toString(Charsets.UTF_8))
                    // A file deleted since (by hand, or the folder is gone) stays deleted.
                    if (file.exists()) {
                        runCatching { overwrite(bytes.copyOfRange(newline + 1, bytes.size), file) }
                            .onSuccess { recovered += file }
                    }
                }
            }
            entry.delete()
        }
        return recovered
    }

    /** Appends to a file, creating it if needed. */
    fun append(data: ByteArray, file: File) {
        if (!file.exists()) return write(data, file)
        FileOutputStream(file, true).use { out ->
            out.write(data)
            out.fd.sync()
        }
        if (observer != null || watcher != null) changed(file, file.readBytes())
    }

    fun delete(file: File) {
        Files.delete(file.toPath())
        changed(file, null)
    }

    /** Moves a file; fails when `destination` exists, unless it is the same file under another
     *  case (a case-only rename on a case-insensitive volume, done through a temporary name:
     *  `Files.move` does nothing when both paths are the same file). */
    fun move(file: File, destination: File) {
        val from = file.toPath()
        val to = destination.toPath()
        if (from == to) return
        if (Files.exists(to) && Files.isSameFile(from, to)) {
            val temp = File(file.parentFile, ".${file.name}.${System.nanoTime()}.moving").toPath()
            Files.move(from, temp)
            Files.move(temp, to)
        } else {
            if (Files.exists(to)) throw IOException("${destination.name} already exists")
            Files.move(from, to)
        }
        if (observer != null || watcher != null) {
            changed(file, null)
            changed(destination, destination.readBytes())
        }
    }
}
