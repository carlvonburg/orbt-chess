package org.orbtchess.orbt.ui.builder

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking
import org.orbtchess.orbt.core.Explorer
import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.StatsStore
import org.orbtchess.orbt.core.StoredStats
import org.orbtchess.orbt.core.databaseDefaultLichess
import org.orbtchess.orbt.core.defaultStudyDefaults
import org.orbtchess.orbt.core.newSidecar
import org.orbtchess.orbt.core.nowTimestamp
import org.orbtchess.orbt.storage.Documents
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.storage.RepertoireLibrary
import org.orbtchess.orbt.storage.ROOT_NODE
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Build's model over a real core session: drafts, saving, deleting, undo, a line from Analysis. */
class BuilderModelTest {
    companion object {
        init {
            // The core's host library (see RepertoireStorageTest).
            if (System.getProperty("jna.library.path") == null) {
                generateSequence(File("").absoluteFile) { it.parentFile }
                    .map { File(it, "core/build/host") }
                    .firstOrNull { it.isDirectory }
                    ?.let { System.setProperty("jna.library.path", it.path) }
            }
        }
    }

    private class MemoryStore : StatsStore {
        override fun load(databaseKey: String): List<StoredStats> = emptyList()
        override fun save(databaseKey: String, epd: String, json: ByteArray) {}
    }

    private fun <T> withDocument(body: suspend CoroutineScope.(RepertoireDocument) -> T): T = runBlocking {
        val folder = Files.createTempDirectory("orbt-builder").toFile()
        try {
            val docs = Documents(RepertoireLibrary(folder, this), Explorer(MemoryStore(), null, null), { defaultStudyDefaults() }, this)
            docs.library.setUp()
            val entry = docs.library.create("Test", newSidecar("Test", Side.WHITE, databaseDefaultLichess(), 100, nowTimestamp()))
            val doc = assertNotNull(docs.open(entry))
            doc.addLine(listOf("e2e4", "e7e5"), ROOT_NODE)
            val result = body(doc)
            docs.closeAll()
            docs.flushAll()
            result
        } finally {
            folder.deleteRecursively()
        }
    }

    @Test
    fun draftSaveDeleteUndo() = withDocument { doc ->
        val model = BuilderModel(doc)
        assertFalse(model.canBack)
        // A saved move is followed; a new one starts the draft.
        model.play("e2e4")
        assertFalse(model.hasDraft)
        model.play("e7e5")
        model.play("g1f3")
        model.play("b8c6")
        assertEquals(listOf("Nf3", "Nc6"), model.draft.map { it.san })
        assertEquals(4, model.movesToBoard.size)
        model.saveDraft()
        assertFalse(model.hasDraft)
        assertEquals(4, doc.savedMoveCount)
        val nf3 = assertNotNull(doc.tree.nodeFollowing(listOf("e2e4", "e7e5", "g1f3")))
        model.delete(nf3)
        assertEquals(2, doc.savedMoveCount)
        model.undo()
        assertEquals(4, doc.savedMoveCount)
        model.close()
    }

    @Test
    fun lineFromAnalysis() = withDocument { doc ->
        val model = BuilderModel(doc)
        model.setLine(listOf(PlayedMove("e4", "e2e4"), PlayedMove("e5", "e7e5"), PlayedMove("Nf3", "g1f3")))
        assertTrue(model.hasDraft)
        assertEquals(listOf("Nf3"), model.draft.map { it.san })
        model.discardDraft()
        assertFalse(model.hasDraft)
        // Closed: a late line is ignored.
        model.close()
        model.setLine(listOf(PlayedMove("d4", "d2d4")))
    }
}
