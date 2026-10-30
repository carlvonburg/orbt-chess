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
import org.orbtchess.orbt.sync.SyncService
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
    val sync = SyncService(
        { platform.folders.repertoires }, platform.folders.support, platform.settings, platform.secrets,
        platform.syncAuth, documents, scope = scope,
    )

    init {
        documents.onOpened = { coverage.want(it.sidecar.database) }
        // A token Lichess rejects is cleared, and the user asked to sign in again.
        scope.launch { explorer.tokenRejected.collect { auth.tokenRejected() } }
    }

    /** At launch: the library, the offline coverage tables, the sync. */
    suspend fun setUp() {
        library.setUp()
        coverage.setUp(platform.folders.repertoires)
        sync.start()
    }

    /** Back in front: files added by hand, tables put in the "Coverage" subfolder, changes
     *  from other devices. */
    suspend fun resume() {
        sync.resume()
        library.refresh()
        coverage.load(File(platform.folders.repertoires, "Coverage"))
    }

    /**
     * Keeps the repertoires in `folder` from now on (the desktop's Settings): the open
     * documents are saved and closed, the library lists the new folder, remembered for the next
     * launch. Nothing is moved or copied.
     */
    suspend fun switchRepertoireFolder(folder: File) {
        if (folder.absoluteFile == platform.folders.repertoires.absoluteFile) return
        documents.closeAll()
        documents.flushAll()
        platform.folders.repertoires = folder
        platform.settings.putString(REPERTOIRE_FOLDER_KEY, folder.absolutePath)
        library.switchTo(folder)
        sync.folderChanged()
        coverage.load(File(folder, "Coverage"))
    }

    /** Leaving: write every pending change (the sync uploads it while it can). */
    suspend fun flush() {
        documents.flushAll()
        sync.background()
    }

    companion object {
        /** The chosen repertoire folder's path (the desktop), read by its platform at launch. */
        const val REPERTOIRE_FOLDER_KEY = "repertoireFolder"
    }
}
