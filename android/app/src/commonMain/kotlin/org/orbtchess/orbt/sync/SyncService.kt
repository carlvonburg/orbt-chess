package org.orbtchess.orbt.sync

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.orbtchess.orbt.core.AuthNeed
import org.orbtchess.orbt.core.HttpRequest
import org.orbtchess.orbt.core.HttpResponse
import org.orbtchess.orbt.core.LocalFile
import org.orbtchess.orbt.core.LocalWrite
import org.orbtchess.orbt.core.RepertoireSync
import org.orbtchess.orbt.core.SyncListener
import org.orbtchess.orbt.core.SyncOp
import org.orbtchess.orbt.core.SyncOpKind
import org.orbtchess.orbt.core.SyncOutcome
import org.orbtchess.orbt.core.SyncState
import org.orbtchess.orbt.core.syncFileKind
import org.orbtchess.orbt.platform.Http
import org.orbtchess.orbt.platform.SecretStore
import org.orbtchess.orbt.platform.Settings
import org.orbtchess.orbt.storage.Documents
import org.orbtchess.orbt.storage.FileAccess
import org.orbtchess.orbt.storage.RepertoireDocument
import java.io.File
import java.lang.ref.WeakReference
import java.util.logging.Logger

/**
 * Runs the core's sync of the repertoire folder with Dropbox or Google Drive
 * (`orbt_core::sync`): sends the requests it hands out one at a time (plus Dropbox's long poll
 * while the app is in front), reports the answers and applies the outcomes to the files. What
 * to download, upload, merge or delete is the core's; this does the IO, the timers and the
 * sign-in.
 *
 * The local files: every file at start (`setLocalFiles`), then every write through
 * `FileAccess` (`FileAccess.observer` → `localChanged`), the documents' saves included. The
 * sync's own writes are reported too, with the bytes the core already holds for that file, so
 * they change nothing there (no upload loop). An open repertoire's files go through its
 * document (`applyRemote`, `removedRemotely`), which merges them into what is on screen.
 *
 * `scope` runs on the main thread: every core call here is made there, except `localChanged`
 * from the observer (the core object locks).
 */
class SyncService(
    /** The repertoire folder. */
    private val folder: File,
    /** Where the sync's state is kept (the support folder). */
    private val support: File,
    private val settings: Settings,
    private val secrets: SecretStore,
    val auth: SyncAuth,
    private val documents: Documents,
    private val send: suspend (HttpRequest) -> HttpResponse? = Http::send,
    private val scope: CoroutineScope = MainScope(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /** Null: repertoires stay on this device. */
    var provider: SyncProvider? by mutableStateOf(null)
        private set
    var account: String? by mutableStateOf(null)
        private set
    var state: SyncState by mutableStateOf(SyncState.Idle)
        private set
    /** Files whose local version is not uploaded yet. */
    var unsynced: List<String> by mutableStateOf(emptyList())
        private set
    var lastError: String? by mutableStateOf(null)
    var isSigningIn: Boolean by mutableStateOf(false)
        private set
    /** The system gave no new token without asking (Drive): only signing in again helps. */
    private var tokenFailed: Boolean by mutableStateOf(false)

    /** Sign in again: the provider refused the sign-in, or no token comes without the user. */
    val needsSignIn: Boolean
        get() = state == SyncState.NeedsSignIn || (state == SyncState.NeedsToken && tokenFailed)

    @Volatile private var core: RepertoireSync? = null
    private var wake: Job? = null
    private var foreground = false
    private var fetchingToken = false
    /** Drive's current access token, so a rejected one is not taken again. */
    private var accessToken: String? = null
    /** One outcome at a time: its files written before the state that names them is saved. */
    private val applying = Mutex()

    /** At launch, after the library: the provider chosen in Settings, if this platform has it. */
    suspend fun start() {
        FileAccess.observer = { file, data ->
            val sync = core
            if (sync != null && file.parentFile?.absoluteFile == folder.absoluteFile && syncFileKind(file.name) != null) {
                // A sync closed meanwhile (signed out) refuses calls; the write itself went through.
                runCatching { sync.localChanged(file.name, data) }
            }
        }
        val chosen = SyncProvider.of(settings.getString(PROVIDER_KEY))?.takeIf { it in auth.providers } ?: return
        val stored = storedCredentials(chosen)
        account = stored?.account
        begin(chosen, stored)
    }

    /** Back in front: look for changes from other devices, long-poll (Dropbox). */
    fun resume() {
        foreground = true
        tokenFailed = false
        core?.setWatching(true)
        core?.syncNow()
    }

    /** In the background: no long poll. */
    fun background() {
        foreground = false
        core?.setWatching(false)
    }

    /** The network is back. */
    fun networkAvailable() {
        core?.resume()
    }

    /** "Sync Now": retries what failed. */
    fun syncNow() {
        tokenFailed = false
        lastError = null
        core?.syncNow()
    }

    /**
     * Signs in to `provider` and syncs with it from now on (the other provider, if any, is
     * left). The local files are kept and merged with the provider's: nothing is deleted.
     * Returns false when the user cancelled or the sign-in failed ([lastError]).
     */
    suspend fun signIn(provider: SyncProvider): Boolean {
        lastError = null
        isSigningIn = true
        try {
            val credentials = auth.signIn(provider) ?: return false
            val previous = storedCredentials(provider)?.account
            stop()
            // Another account (or one we can't tell): what was synced says nothing about its
            // files, so start over (both sides are merged once).
            if (credentials.account == null || credentials.account != previous || this.provider != provider) {
                withContext(Dispatchers.IO) { stateFile(provider).delete() }
            }
            storeCredentials(provider, credentials)
            settings.putString(PROVIDER_KEY, provider.key)
            account = credentials.account
            begin(provider, credentials)
            return true
        } catch (e: SyncSignInException) {
            lastError = e.message
            return false
        } finally {
            isSigningIn = false
        }
    }

    /**
     * Stops syncing: the files stay on this device, the provider's stay there. The sign-in is
     * revoked on the provider's side (the core's requests: Dropbox's `auth/token/revoke`; best
     * effort, offline leaves it), and the platform's own sign-in is dropped (Drive's token).
     */
    suspend fun signOut() {
        val provider = provider ?: return
        val stored = storedCredentials(provider)
        val credentials = SyncCredentials(accessToken, refreshToken = stored?.refreshToken, account = stored?.account)
        val sync = core
        stop(close = false)
        sync?.let { revoke(it) }
        sync?.close()
        secrets.remove(secretKey(provider))
        settings.remove(PROVIDER_KEY)
        withContext(Dispatchers.IO) { stateFile(provider).delete() }
        this.provider = null
        account = null
        lastError = null
        unsynced = emptyList()
        state = SyncState.Idle
        try {
            auth.signOut(provider, credentials)
        } catch (e: SyncSignInException) {
            log.warning("sync sign-out: ${e.message}")
        }
    }

    private suspend fun begin(provider: SyncProvider, credentials: SyncCredentials?) {
        val saved = withContext(Dispatchers.IO) { runCatching { stateFile(provider).readBytes() }.getOrDefault(ByteArray(0)) }
        val sync = when (provider) {
            SyncProvider.Dropbox -> RepertoireSync.dropbox(auth.dropboxAppKey, saved)
            SyncProvider.Drive -> RepertoireSync.drive(saved)
        }
        this.provider = provider
        tokenFailed = false
        accessToken = credentials?.accessToken
        core = sync
        sync.setListener(Listener(this))
        if (credentials != null) sync.setCredentials(credentials.accessToken, credentials.expiresAt, credentials.refreshToken)
        val files = withContext(Dispatchers.IO) {
            folder.listFiles().orEmpty()
                .filter { it.isFile && syncFileKind(it.name) != null }
                .mapNotNull { file -> runCatching { LocalFile(file.name, FileAccess.read(file)) }.getOrNull() }
        }
        if (core !== sync) return
        sync.setLocalFiles(files)
        sync.setWatching(foreground)
        sync.syncNow()
    }

    private fun stop(close: Boolean = true) {
        val sync = core ?: return
        core = null
        wake?.cancel()
        wake = null
        if (close) sync.close()
    }

    /** Sends the core's sign-out requests until there are none (at most a refresh and a revoke). */
    private suspend fun revoke(sync: RepertoireSync) {
        repeat(MAX_SIGN_OUT_REQUESTS) {
            val request = sync.signOutRequest(clock()) ?: return
            val response = send(request)
            sync.onSignOutResponse(response, clock())
            if (response == null) return
        }
    }

    // MARK: The core's queue

    /** Sends what the core hands out and sleeps until it wants to be asked again. */
    fun pump() {
        val sync = core ?: return
        val poll = sync.poll(clock())
        refresh(sync)
        poll.needs?.let { need(sync, it) }
        for (op in poll.ops) scope.launch { perform(sync, op) }
        wake?.cancel()
        wake = poll.wakeAt?.let { wakeAt ->
            scope.launch {
                val delay = wakeAt - clock()
                if (delay > 0) delay(delay)
                if (isActive) pump()
            }
        }
    }

    private suspend fun perform(sync: RepertoireSync, op: SyncOp) {
        val response = send(op.request)
        if (op.kind != SyncOpKind.WATCH) {
            log.info("sync ${op.kind} ${op.file.orEmpty()} ${response?.status?.toString() ?: "offline"}")
        }
        // Signed out or switched meanwhile.
        if (core !== sync) return
        val outcome = sync.onResponse(op, response, clock())
        apply(sync, outcome)
    }

    private suspend fun apply(sync: RepertoireSync, outcome: SyncOutcome) {
        applying.withLock {
            if (core !== sync) return
            if (outcome.writes.isNotEmpty() || outcome.deletes.isNotEmpty()) {
                applyFiles(outcome.writes, outcome.deletes)
                documents.library.refresh()
            }
            // After the files: a state naming versions not written yet would upload the old ones.
            val provider = provider
            if (outcome.saveState && provider != null) {
                val data = sync.savedState()
                withContext(Dispatchers.IO) { FileAccess.write(data, stateFile(provider)) }
            }
        }
        outcome.needs?.let { need(sync, it) }
        refresh(sync)
    }

    /** Writes and deletes the local files; an open repertoire's through its document. */
    private suspend fun applyFiles(writes: List<LocalWrite>, deletes: List<String>) {
        class Remote(var pgn: ByteArray? = null, var sidecar: ByteArray? = null, var revlog: ByteArray? = null)
        val open = mutableMapOf<RepertoireDocument, Remote>()
        for (write in writes) {
            val document = documentOf(write.name)
            if (document == null) {
                withContext(Dispatchers.IO) { FileAccess.write(write.data, File(folder, write.name)) }
                continue
            }
            val remote = open.getOrPut(document) { Remote() }
            when (write.name) {
                document.pgnFile.name -> remote.pgn = write.data
                document.sidecarFile.name -> remote.sidecar = write.data
                else -> remote.revlog = write.data
            }
        }
        for ((document, remote) in open) document.applyRemote(remote.pgn, remote.sidecar, remote.revlog)
        for (name in deletes) {
            documentOf(name)?.takeIf { it.pgnFile.name == name }?.removedRemotely()
            withContext(Dispatchers.IO) {
                val file = File(folder, name)
                if (file.exists()) runCatching { FileAccess.delete(file) }
            }
        }
    }

    private fun documentOf(name: String): RepertoireDocument? = documents.documents.values.firstOrNull {
        it.pgnFile.name == name || it.sidecarFile.name == name || it.revlogFile.name == name
    }

    private fun refresh(sync: RepertoireSync) {
        if (core !== sync) return
        state = sync.state()
        unsynced = sync.unsyncedFiles()
    }

    /** Drive's token expired or was refused: ask the system for a new one, without the user. */
    private fun need(sync: RepertoireSync, need: AuthNeed) {
        val provider = provider ?: return
        if (need != AuthNeed.TOKEN || fetchingToken || tokenFailed) return
        fetchingToken = true
        scope.launch {
            try {
                val credentials = auth.token(provider, accessToken)
                if (core !== sync) return@launch
                if (credentials?.accessToken == null) {
                    tokenFailed = true
                } else {
                    accessToken = credentials.accessToken
                    credentials.account?.let { account = it }
                    sync.setCredentials(credentials.accessToken, credentials.expiresAt, null)
                }
            } catch (e: SyncSignInException) {
                lastError = e.message
                tokenFailed = true
            } finally {
                fetchingToken = false
            }
        }
    }

    // MARK: Stored sign-in

    private fun stateFile(provider: SyncProvider) = File(support, "Sync-${provider.key}.json")

    private fun secretKey(provider: SyncProvider) = "sync-${provider.key}"

    /** One line each: Dropbox's refresh token (empty for Drive), the account (may be empty). */
    private fun storedCredentials(provider: SyncProvider): SyncCredentials? {
        val parts = secrets.get(secretKey(provider))?.split("\n") ?: return null
        if (parts.size != 2) return null
        return SyncCredentials(refreshToken = parts[0].ifEmpty { null }, account = parts[1].ifEmpty { null })
    }

    private fun storeCredentials(provider: SyncProvider, credentials: SyncCredentials) {
        secrets.set(secretKey(provider), "${credentials.refreshToken.orEmpty()}\n${credentials.account.orEmpty()}")
    }

    /** The core asks to be polled from any thread; hop to the main thread so it is not re-entered. */
    private class Listener(service: SyncService) : SyncListener {
        private val service = WeakReference(service)
        override fun wake() {
            val service = service.get() ?: return
            service.scope.launch { service.pump() }
        }
    }

    companion object {
        const val PROVIDER_KEY = "syncProvider"
        private const val MAX_SIGN_OUT_REQUESTS = 3
        private val log = Logger.getLogger("org.orbtchess.orbt.sync")
    }
}
