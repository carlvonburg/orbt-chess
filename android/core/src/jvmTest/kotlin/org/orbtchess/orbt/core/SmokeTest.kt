package org.orbtchess.orbt.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A stats store that keeps nothing: the tests never fetch. */
class NoStats : StatsStore {
    override fun load(databaseKey: String): List<StoredStats> = emptyList()
    override fun save(databaseKey: String, epd: Epd, json: ByteArray) {}
}

class NoNotices : EngineListener {
    override fun changed() {}
}

/** The bindings smoke test, as `apple/OpeningCoreRust/Tests/.../SmokeTests.swift`. */
class SmokeTest {
    @Test
    fun callsIntoRust() {
        assertTrue(coreVersion().isNotEmpty())
        assertEquals(20, Position.start().legalMoves().size)
        assertNull(positionFromFen("nonsense"))
    }

    @Test
    fun opensARepertoire() {
        val sidecar = newSidecar("smoke", Side.WHITE, ExplorerDatabase.Masters, 100, System.currentTimeMillis())
        val explorer = Explorer(NoStats(), null, null)
        val opened = openRepertoire("1. e4 e5 2. Nf3 Nc6 (2... Nf6) *", sidecar, defaultStudyDefaults(), explorer)
        val doc = opened.document
        val e4 = assertNotNull(doc.childBySan(doc.root().id, "e4"))
        val e5 = assertNotNull(doc.childBySan(e4, "e5"))
        val nf3 = assertNotNull(doc.childBySan(e5, "Nf3"))
        assertNotNull(doc.childBySan(nf3, "Nc6"))
        assertNotNull(doc.childBySan(nf3, "Nf6"))
    }

    @Test
    fun stockfishAnalysesThroughTheBindings() {
        val engine = Engine(EngineKind.STOCKFISH)
        engine.setListener(NoNotices())
        engine.start(null)
        val settings = defaultEngineSettings().apply {
            cloud = false
            movetimeMs = 500u
            threads = 1u
        }
        engine.analyse(Position.start().fen(), listOf("e2e4"), settings, System.currentTimeMillis().toULong())
        repeat(40) {
            val lines = engine.lines()
            if (lines.lines.size >= 3 && !lines.searching) return@repeat
            Thread.sleep(100)
        }
        val shown = engine.lines()
        assertEquals(3, shown.lines.size)
        assertEquals(EvalSource.LOCAL, shown.source)
        assertEquals("SF 19 · 1 MB", engine.name())
        engine.quit()
    }

    @Test
    fun analysisBoardVariations() {
        val analysis = AnalysisSession(null, listOf("e2e4", "e7e5"), Side.WHITE)
        assertTrue(analysis.back())
        assertTrue(analysis.playUci("c7c5"))
        assertEquals("1. e4 e5 (1... c5) *", analysis.pgn())
    }
}
