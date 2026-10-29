package org.orbtchess.orbt.ui.analysis

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking
import org.orbtchess.orbt.core.Explorer
import org.orbtchess.orbt.core.MoveListRow
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.StatsStore
import org.orbtchess.orbt.core.StoredStats
import org.orbtchess.orbt.core.databaseDefaultLichess
import org.orbtchess.orbt.core.defaultStudyDefaults
import org.orbtchess.orbt.core.newSidecar
import org.orbtchess.orbt.core.nowTimestamp
import org.orbtchess.orbt.storage.Documents
import org.orbtchess.orbt.storage.ROOT_NODE
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.storage.RepertoireLibrary
import org.orbtchess.orbt.ui.builder.BuilderModel
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** The analysis board's model over a real core session: moves, variations, leaving for Build. */
class AnalysisModelTest {
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

    /** A repertoire with 1. e4 e5 saved, in a temporary folder. */
    private fun <T> withDocument(body: suspend CoroutineScope.(RepertoireDocument) -> T): T = runBlocking {
        val folder = Files.createTempDirectory("orbt-analysis").toFile()
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
    fun movesAndVariations() = withDocument { doc ->
        val model = AnalysisModel(doc, null, emptyList(), Side.WHITE, AnalysisModel.Origin.Study)
        assertFalse(model.state.canBack)
        model.play("e2e4")
        model.play("c7c5")
        model.back()
        model.play("e7e5")
        assertEquals(listOf("e4", "e5"), model.state.movesToBoard.map { it.san })
        // The main line's rows, and the variation under the move it replaces.
        assertTrue(model.state.moveList.any { it is MoveListRow.Variation })
        assertNotNull(model.state.currentRow)
        model.goToPly(0)
        assertEquals(0, model.state.movesToBoard.size)
        assertTrue(model.state.canForward)
        model.goToPly(2)
        assertEquals(2, model.state.movesToBoard.size)
        model.flip()
        assertEquals(Side.BLACK, model.state.orientation)
        assertTrue(model.pgn().contains("e4"))
        model.close()
        // Closed: actions are no-ops, the last state stays readable.
        model.play("g1f3")
        assertEquals(2, model.state.movesToBoard.size)
        assertEquals("", model.pgn())
    }

    @Test
    fun finishHandsTheLineToBuild() = withDocument { doc ->
        val builder = BuilderModel(doc)
        val model = AnalysisModel(doc, null, emptyList(), Side.WHITE, AnalysisModel.Origin.Build(builder))
        model.play("e2e4")
        model.play("e7e5")
        model.play("g1f3")
        model.finish()
        model.finish()
        model.close()
        // The saved moves are followed; Nf3 is the draft.
        assertEquals(listOf("e4", "e5", "Nf3"), builder.movesToBoard.map { it.san })
        assertEquals(listOf("Nf3"), builder.draft.map { it.san })
        builder.close()
    }
}
