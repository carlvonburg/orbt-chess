package org.orbtchess.orbt

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import org.orbtchess.orbt.engine.EngineDefaults
import org.orbtchess.orbt.engine.EngineNetwork
import org.orbtchess.orbt.engine.EngineService
import org.orbtchess.orbt.explorer.CoverageTables
import org.orbtchess.orbt.explorer.ExplorerCacheStore
import org.orbtchess.orbt.explorer.ExplorerService
import org.orbtchess.orbt.lichess.LichessAuth
import org.orbtchess.orbt.platform.PlatformServices
import org.orbtchess.orbt.storage.Documents
import org.orbtchess.orbt.storage.RepertoireLibrary
import org.orbtchess.orbt.storage.TrainingDefaults
import org.orbtchess.orbt.ui.tour.TourGuide
import java.io.File

/**
 * Shared services and the open documents, as `apple/ORBT/App/AppModel.swift`. Built once by
 * each platform's entry point; `scope` runs on the main thread.
 */
class AppModel(val platform: PlatformServices, private val scope: CoroutineScope = MainScope()) {
    val auth = LichessAuth(platform.secrets)
    val stats = ExplorerCacheStore.inFolder(platform.folders.support)
    val explorer = ExplorerService(stats, platform.settings, token = { auth.token }, scope = scope)
    val coverage = CoverageTables(explorer, platform.folders.support, scope = scope)
    val library = RepertoireLibrary(platform.folders.repertoires, scope)
    val training = TrainingDefaults(platform.settings)
    val documents = Documents(library, explorer.core, { training.studyDefaults }, scope)
    val engineDefaults = EngineDefaults(platform.settings, platform.processors)
    val engineNetwork = EngineNetwork(platform.folders, scope)
    val engine = EngineService(engineNetwork, engineDefaults, scope)
    val tour = TourGuide(platform.settings)

    init {
        documents.onOpened = { coverage.want(it.sidecar.database) }
        // A token Lichess rejects is cleared, and the user asked to sign in again.
        scope.launch { explorer.tokenRejected.collect { auth.tokenRejected() } }
    }

    /** At launch: the library and the offline coverage tables. */
    suspend fun setUp() {
        library.setUp()
        coverage.setUp(platform.folders.repertoires)
    }

    /** Back in front: files added by hand, tables put in the "Coverage" subfolder. */
    suspend fun resume() {
        library.refresh()
        coverage.load(File(platform.folders.repertoires, "Coverage"))
    }

    /** Leaving: write every pending change. */
    suspend fun flush() = documents.flushAll()
}
