package org.orbtchess.orbt.platform

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.orbtchess.orbt.BuildConfig
import org.orbtchess.orbt.sync.AndroidSyncAuth
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

fun androidPlatform(context: Context): PlatformServices {
    val app = context.applicationContext
    return PlatformServices(
        folders = AppFolders(
            repertoires = File(app.filesDir, "Repertoires"),
            support = File(app.filesDir, "Support"),
        ),
        settings = PreferenceSettings(app.getSharedPreferences("settings", Context.MODE_PRIVATE)),
        secrets = KeystoreSecrets(app.getSharedPreferences("secrets", Context.MODE_PRIVATE)),
        openUrl = { url ->
            app.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        },
        syncAuth = AndroidSyncAuth(app, BuildConfig.DROPBOX_APP_KEY),
    )
}

private class PreferenceSettings(private val prefs: SharedPreferences) : Settings {
    override fun getInt(key: String) = if (prefs.contains(key)) prefs.getInt(key, 0) else null
    override fun putInt(key: String, value: Int) = prefs.edit().putInt(key, value).apply()
    override fun getLong(key: String) = if (prefs.contains(key)) prefs.getLong(key, 0) else null
    override fun putLong(key: String, value: Long) = prefs.edit().putLong(key, value).apply()
    override fun getBoolean(key: String) = if (prefs.contains(key)) prefs.getBoolean(key, false) else null
    override fun putBoolean(key: String, value: Boolean) = prefs.edit().putBoolean(key, value).apply()
    override fun getString(key: String): String? = prefs.getString(key, null)
    override fun putString(key: String, value: String) = prefs.edit().putString(key, value).apply()
    override fun remove(key: String) = prefs.edit().remove(key).apply()
}

/** Values encrypted with AES-GCM under a key that never leaves the Android Keystore. */
private class KeystoreSecrets(private val prefs: SharedPreferences) : SecretStore {
    private val alias = "orbt.secrets"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    override fun get(key: String): String? {
        val stored = prefs.getString(key, null) ?: return null
        return try {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12))
            String(cipher.doFinal(bytes, 12, bytes.size - 12), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }

    override fun set(key: String, value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(key, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    override fun remove(key: String) = prefs.edit().remove(key).apply()
}
