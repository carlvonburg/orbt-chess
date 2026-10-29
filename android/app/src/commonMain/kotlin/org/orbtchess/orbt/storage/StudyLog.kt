package org.orbtchess.orbt.storage

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.orbtchess.orbt.core.RevlogEntry
import org.orbtchess.orbt.core.decodeRevlog
import java.io.File

/** Review logs of library entries, from the open document or read from disk. */
object StudyLog {
    suspend fun revlog(entry: RepertoireEntry, documents: Documents): List<RevlogEntry> {
        documents.documents[entry.id]?.let { return it.reviewLog() }
        return read(RepertoireLibrary.revlogFile(entry.pgnFile))
    }

    suspend fun read(file: File): List<RevlogEntry> = decodeRevlog(readData(file))

    /** The log file's bytes, read off the main thread; empty when there is none. */
    suspend fun readData(file: File): ByteArray = withContext(Dispatchers.IO) {
        runCatching { FileAccess.read(file) }.getOrDefault(ByteArray(0))
    }
}
