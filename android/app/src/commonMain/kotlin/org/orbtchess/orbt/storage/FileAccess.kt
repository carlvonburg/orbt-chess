package org.orbtchess.orbt.storage

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Reads and writes of the repertoire files (`apple/ORBT/Storage/FileAccess.swift` without the
 * file coordination: no iCloud here, the app is the only writer on the device). Blocking: call
 * from a background dispatcher, never the main thread.
 */
object FileAccess {
    /**
     * Told after every file this package writes, appends to, moves or deletes (`data` null:
     * deleted), with the file's whole contents; called on the IO thread. For the sync
     * (`RepertoireSync.localChanged`), which comes later.
     */
    @Volatile var observer: ((file: File, data: ByteArray?) -> Unit)? = null

    fun read(file: File): ByteArray = file.readBytes()

    /** Writes a temporary file next to `file`, then renames it over `file`, so a reader never
     *  sees half a file and a crash leaves the old one. */
    fun write(data: ByteArray, file: File) {
        file.parentFile?.mkdirs()
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
        observer?.invoke(file, data)
    }

    /** Appends to a file, creating it if needed. */
    fun append(data: ByteArray, file: File) {
        if (!file.exists()) return write(data, file)
        FileOutputStream(file, true).use { out ->
            out.write(data)
            out.fd.sync()
        }
        observer?.let { it(file, file.readBytes()) }
    }

    fun delete(file: File) {
        Files.delete(file.toPath())
        observer?.invoke(file, null)
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
        observer?.let {
            it(file, null)
            it(destination, destination.readBytes())
        }
    }
}
