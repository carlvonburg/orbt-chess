package org.orbtchess.orbt.storage

import androidx.compose.runtime.mutableStateMapOf
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.orbtchess.orbt.core.Explorer
import org.orbtchess.orbt.core.StudyDefaults

/**
 * The open documents (the document half of `apple/ORBT/App/AppModel.swift`). Main-thread
 * confined: `scope` runs on the main thread (e.g. `MainScope()`).
 */
class Documents(
    val library: RepertoireLibrary,
    /** The core's explorer, shared by every document (the explorer service's). */
    private val explorer: Explorer,
    /** The daily-practice defaults, read when a document opens (`TrainingDefaults.studyDefaults`). */
    private val defaults: () -> StudyDefaults,
    private val scope: CoroutineScope,
) {
    /** The open documents, by entry id. */
    val documents: MutableMap<String, RepertoireDocument> = mutableStateMapOf()
    /** Why an entry could not be opened, by entry id. */
    val openErrors: MutableMap<String, String> = mutableStateMapOf()
    /** Told about each document opened (the coverage tables want its database). */
    var onOpened: ((RepertoireDocument) -> Unit)? = null

    /** An open repertoire was deleted elsewhere (another device, the folder): its screens close. */
    var onRemoved: ((entryId: String) -> Unit)? = null

    private val opening = mutableMapOf<String, Deferred<RepertoireDocument?>>()
    /** Closed documents' last saves (done ones return at once); opening the entry again waits
     *  for them. */
    private val closing = mutableMapOf<String, Job>()
    /** Old entry id → new one, for renamed repertoires, so open screens keep their document. */
    private val renamedIds = mutableStateMapOf<String, String>()

    /** Opens (or returns the already open) document for a library entry. The files are read
     *  and parsed in the background; concurrent calls for the same entry share one load. */
    suspend fun open(entry: RepertoireEntry): RepertoireDocument? {
        documents[entry.id]?.let { return it }
        opening[entry.id]?.let { return it.await() }
        val task = scope.async {
            try {
                closing[entry.id]?.join()
                val loaded = RepertoireDocument.load(entry.pgnFile, entry.sidecarFile, defaults(), explorer)
                documents[entry.id]?.let { return@async it }
                val doc = RepertoireDocument.create(entry, loaded, scope)
                doc.onRemoved = {
                    if (documents[doc.entryId] === doc) {
                        documents.remove(doc.entryId)
                        onRemoved?.invoke(doc.entryId)
                        scope.launch { library.refresh() }
                    }
                }
                doc.onRenamed = { oldId ->
                    moved(doc, oldId)
                    scope.launch { library.refresh() }
                }
                onOpened?.invoke(doc)
                documents[entry.id] = doc
                openErrors.remove(entry.id)
                doc
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                openErrors[entry.id] = "Could not open ${entry.name}: ${e.message}"
                null
            } finally {
                opening.remove(entry.id)
            }
        }
        if (!task.isCompleted) opening[entry.id] = task
        return task.await()
    }

    suspend fun rename(document: RepertoireDocument, name: String) {
        val oldId = document.entryId
        document.rename(name, library)
        moved(document, oldId)
    }

    private fun moved(document: RepertoireDocument, oldId: String) {
        if (document.entryId == oldId) return
        if (documents[oldId] === document) documents.remove(oldId)
        documents[document.entryId] = document
        renamedIds[oldId] = document.entryId
    }

    /** The current id of an entry that may have been renamed since `id` was taken. */
    fun currentId(id: String): String {
        var current = id
        while (true) {
            val next = renamedIds[current] ?: return current
            if (next == current) return current
            current = next
        }
    }

    /** Closes the document; it finishes saving in the background. */
    fun close(entryId: String) {
        openErrors.remove(entryId)
        val doc = documents.remove(entryId) ?: return
        val previous = closing[entryId]
        closing[entryId] = scope.launch {
            previous?.join()
            doc.close()
        }
    }

    /** Deletes a repertoire's files. Its open document is dropped without saving, so nothing
     *  writes the files again. */
    suspend fun delete(entry: RepertoireEntry) {
        documents.remove(entry.id)?.discard()
        openErrors.remove(entry.id)
        closing[entry.id]?.join()
        library.delete(entry)
    }

    /** Writes every pending change, including documents still closing. */
    suspend fun flushAll() {
        for (doc in documents.values.toList()) doc.flush()
        for (job in closing.values.toList()) job.join()
    }

    fun closeAll() {
        for (id in documents.keys.toList()) close(id)
    }

    /** A repertoire's PGN as saved, for export: an open document writes what is pending first. */
    suspend fun pgnForExport(entry: RepertoireEntry): ByteArray {
        documents[entry.id]?.flush()
        closing[entry.id]?.join()
        return withContext(Dispatchers.IO) { FileAccess.read(entry.pgnFile) }
    }
}
