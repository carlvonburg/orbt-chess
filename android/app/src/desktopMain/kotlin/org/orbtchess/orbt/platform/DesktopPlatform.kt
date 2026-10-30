package org.orbtchess.orbt.platform

import org.orbtchess.orbt.lichess.LoopbackAuthBrowser
import java.awt.Desktop
import java.io.File
import java.net.URI
import java.util.prefs.Preferences

/**
 * The desktop's folders: the repertoires in a folder the user may put inside Google Drive for
 * desktop, Dropbox or OneDrive (a picker comes in step 6; for now `~/ORBT Chess`), the app's
 * data in the OS's per-user application folder.
 */
fun desktopPlatform(): PlatformServices {
    val home = File(System.getProperty("user.home"))
    val os = System.getProperty("os.name").lowercase()
    val support = when {
        os.contains("win") -> File(System.getenv("APPDATA") ?: home.path, "ORBT Chess")
        os.contains("mac") -> File(home, "Library/Application Support/ORBT Chess")
        else -> File(System.getenv("XDG_DATA_HOME") ?: File(home, ".local/share").path, "orbt-chess")
    }
    val prefs = Preferences.userRoot().node("org/orbtchess/orbt")
    val openUrl = { url: String ->
        if (Desktop.isDesktopSupported()) Desktop.getDesktop().browse(URI(url))
    }
    return PlatformServices(
        folders = AppFolders(repertoires = File(home, "ORBT Chess"), support = support),
        settings = PrefsSettings(prefs.node("settings")),
        // TODO(step 6): the OS credential store (Windows Credential Manager, libsecret).
        secrets = PrefsSecrets(prefs.node("secrets")),
        openUrl = openUrl,
        authBrowser = LoopbackAuthBrowser(openUrl),
    )
}

private class PrefsSettings(private val prefs: Preferences) : Settings {
    private fun has(key: String) = prefs.get(key, null) != null
    override fun getInt(key: String) = if (has(key)) prefs.getInt(key, 0) else null
    override fun putInt(key: String, value: Int) = prefs.putInt(key, value)
    override fun getLong(key: String) = if (has(key)) prefs.getLong(key, 0) else null
    override fun putLong(key: String, value: Long) = prefs.putLong(key, value)
    override fun getBoolean(key: String) = if (has(key)) prefs.getBoolean(key, false) else null
    override fun putBoolean(key: String, value: Boolean) = prefs.putBoolean(key, value)
    override fun getString(key: String): String? = prefs.get(key, null)
    override fun putString(key: String, value: String) = prefs.put(key, value)
    override fun remove(key: String) = prefs.remove(key)
}

private class PrefsSecrets(private val prefs: Preferences) : SecretStore {
    override fun get(key: String): String? = prefs.get(key, null)
    override fun set(key: String, value: String) = prefs.put(key, value)
    override fun remove(key: String) = prefs.remove(key)
}
