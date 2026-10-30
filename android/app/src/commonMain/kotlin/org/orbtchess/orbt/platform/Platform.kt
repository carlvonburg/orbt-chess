package org.orbtchess.orbt.platform

import org.orbtchess.orbt.lichess.AuthBrowser
import org.orbtchess.orbt.sync.NoSyncAuth
import org.orbtchess.orbt.sync.SyncAuth
import java.io.File

/**
 * Where the app keeps its files, set up by each platform's entry point. The Swift app's
 * equivalents: the iCloud Drive folder (or Documents) for repertoires, Application Support.
 */
class AppFolders(
    /** The repertoires: `<Name>.pgn`, `<Name>.otrep.json`, `<Name>.otlog.jsonl`. */
    val repertoires: File,
    /** The app's own data: coverage tables, the engine's full net, the stats cache. */
    val support: File,
) {
    init {
        repertoires.mkdirs()
        support.mkdirs()
    }
}

/** Small settings (UserDefaults on Apple): SharedPreferences on Android, java.util.prefs on the desktop. */
interface Settings {
    fun getInt(key: String): Int?
    fun putInt(key: String, value: Int)
    fun getLong(key: String): Long?
    fun putLong(key: String, value: Long)
    fun getBoolean(key: String): Boolean?
    fun putBoolean(key: String, value: Boolean)
    fun getString(key: String): String?
    fun putString(key: String, value: String)
    fun remove(key: String)
}

/**
 * Secrets (the Keychain on Apple): the Lichess token, Dropbox's refresh token.
 * Android encrypts them with a Keystore key; the desktop uses the user's private settings.
 */
interface SecretStore {
    fun get(key: String): String?
    fun set(key: String, value: String)
    fun remove(key: String)
}

/** What each platform provides; built once by its entry point and handed to the app. */
class PlatformServices(
    val folders: AppFolders,
    val settings: Settings,
    val secrets: SecretStore,
    /** Opens a page (Analyse on Lichess): a Custom Tab on Android, the default browser on the desktop. */
    val openUrl: (String) -> Unit,
    /**
     * The browser for the Lichess sign-in (`webAuthenticationSession` in the Swift app):
     * a Custom Tab on Android, the default browser and a loopback redirect on the desktop.
     */
    val authBrowser: AuthBrowser,
    /** Logical processors, for the engine's threads. */
    val processors: Int = Runtime.getRuntime().availableProcessors(),
    /** Dropbox and Google Drive sign-ins (Android, the desktop). */
    val syncAuth: SyncAuth = NoSyncAuth,
)
