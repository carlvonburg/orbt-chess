package org.orbtchess.orbt.sync

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.ClearTokenRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import com.google.android.gms.tasks.Task
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject
import org.orbtchess.orbt.core.SignInException
import org.orbtchess.orbt.core.lichessParseCallback
import org.orbtchess.orbt.core.lichessRandomString
import org.orbtchess.orbt.lichess.CustomTabAuthBrowser
import org.orbtchess.orbt.platform.Http
import java.security.SecureRandom
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Android's sign-ins for the sync: Dropbox with PKCE in a Custom Tab (a refresh token, which
 * the core uses from then on), Google Drive through Play services' `AuthorizationClient` (an
 * access token for `drive.file`, asked again without the user when it expires).
 */
class AndroidSyncAuth(private val context: Context, override val dropboxAppKey: String) : SyncAuth {
    override val providers: List<SyncProvider> = SyncProvider.entries

    override suspend fun signIn(provider: SyncProvider): SyncCredentials? = when (provider) {
        SyncProvider.Dropbox -> dropboxSignIn()
        SyncProvider.Drive -> driveToken(interactive = true, rejected = null)
    }

    override suspend fun token(provider: SyncProvider, rejected: String?): SyncCredentials? = when (provider) {
        // The core refreshes Dropbox's tokens itself.
        SyncProvider.Dropbox -> null
        SyncProvider.Drive -> driveToken(interactive = false, rejected = rejected)
    }

    override suspend fun signOut(provider: SyncProvider, credentials: SyncCredentials?) {
        // Dropbox: the refresh token is forgotten (the user can remove the app in Dropbox's
        // settings, Connected apps). Drive: the system's cached token is dropped.
        if (provider == SyncProvider.Drive) credentials?.accessToken?.let { clearDriveToken(it) }
    }

    // MARK: Dropbox

    private suspend fun dropboxSignIn(): SyncCredentials? {
        if (dropboxAppKey.isEmpty()) throw SyncSignInException("This build has no Dropbox app key.")
        val verifier = lichessRandomString(randomBytes(64))
        val state = lichessRandomString(randomBytes(32))
        val callback = CustomTabAuthBrowser(context, DROPBOX_REDIRECT_URI).authenticate { uri ->
            dropboxAuthorizeUrl(dropboxAppKey, verifier, state, uri)
        } ?: return null
        // The redirect's query is OAuth's, as Lichess's: state, then code or error.
        val code = try {
            lichessParseCallback(callback, state)
        } catch (_: SignInException) {
            throw SyncSignInException("Dropbox's answer did not match the sign-in.")
        } ?: return null  // the user declined
        val response = Http.send(dropboxTokenRequest(dropboxAppKey, code, verifier))
            ?: throw SyncSignInException("Could not reach Dropbox.")
        val json = runCatching { JSONObject(response.body.toString(Charsets.UTF_8)) }.getOrNull()
        val refresh = json?.optString("refresh_token")?.ifEmpty { null }
        val access = json?.optString("access_token")?.ifEmpty { null }
        if (response.status.toInt() != 200 || refresh == null || access == null) {
            val reason = json?.optString("error_description")?.ifEmpty { null } ?: "error ${response.status}"
            throw SyncSignInException("Dropbox refused the sign-in ($reason).")
        }
        val expiresIn = json.optLong("expires_in", 0).takeIf { it > 0 }
        val account = Http.send(dropboxAccountRequest(access))?.takeIf { it.status.toInt() == 200 }?.let {
            runCatching { JSONObject(it.body.toString(Charsets.UTF_8)).optString("email").ifEmpty { null } }.getOrNull()
        }
        return SyncCredentials(
            accessToken = access,
            expiresAt = expiresIn?.let { System.currentTimeMillis() + it * 1000 },
            refreshToken = refresh,
            account = account,
        )
    }

    // MARK: Google Drive

    private val driveRequest: AuthorizationRequest
        get() = AuthorizationRequest.builder().setRequestedScopes(listOf(Scope(DRIVE_FILE_SCOPE))).build()

    /** A token for `drive.file`: from the system when the user consented before, else (only
     *  when `interactive`) from Google's consent screen. */
    private suspend fun driveToken(interactive: Boolean, rejected: String?): SyncCredentials? {
        val client = Identity.getAuthorizationClient(context)
        rejected?.let { clearDriveToken(it) }
        try {
            var result = client.authorize(driveRequest).await()
            if (result.hasResolution()) {
                val pending = result.pendingIntent
                if (!interactive || pending == null) return null
                val data = DriveConsentActivity.consent(context, pending) ?: return null
                result = client.getAuthorizationResultFromIntent(data)
            }
            return credentials(result)
        } catch (e: ApiException) {
            throw SyncSignInException("Google Drive refused the sign-in (${e.statusCode}: ${e.message}).")
        }
    }

    private fun credentials(result: AuthorizationResult): SyncCredentials? {
        val token = result.accessToken ?: return null
        return SyncCredentials(
            accessToken = token,
            // Google's tokens last an hour; the system says when only through a 401. Asked
            // again before, without the user.
            expiresAt = System.currentTimeMillis() + DRIVE_TOKEN_MS,
            account = result.toGoogleSignInAccount()?.email,
        )
    }

    private suspend fun clearDriveToken(token: String) {
        runCatching {
            Identity.getAuthorizationClient(context).clearToken(ClearTokenRequest.builder().setToken(token).build()).await()
        }
    }

    private companion object {
        const val DRIVE_FILE_SCOPE = "https://www.googleapis.com/auth/drive.file"
        const val DRIVE_TOKEN_MS = 50 * 60 * 1000L
        val random = SecureRandom()

        fun randomBytes(count: Int) = ByteArray(count).also(random::nextBytes)
    }
}

private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
    addOnSuccessListener { continuation.resume(it) }
    addOnFailureListener { continuation.resumeWithException(it) }
    addOnCanceledListener { continuation.cancel() }
}

/** Shows Google's consent screen (the authorization's `PendingIntent`) and hands back its result. */
class DriveConsentActivity : ComponentActivity() {
    private val launcher = registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        pending?.complete(result.data.takeIf { result.resultCode == RESULT_OK })
        pending = null
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The process was restarted: nobody waits for this consent any more.
        if (pending == null) return finish()
        if (savedInstanceState == null) {
            @Suppress("DEPRECATION")
            val intent = intent.getParcelableExtra<PendingIntent>(EXTRA_INTENT) ?: return finish()
            launcher.launch(IntentSenderRequest.Builder(intent).build())
        }
    }

    companion object {
        private const val EXTRA_INTENT = "intent"
        private var pending: CompletableDeferred<Intent?>? = null

        /** The consent's result, or null when the user declined or went back. */
        suspend fun consent(context: Context, intent: PendingIntent): Intent? {
            val result = CompletableDeferred<Intent?>()
            pending?.complete(null)
            pending = result
            context.startActivity(
                Intent(context, DriveConsentActivity::class.java)
                    .putExtra(EXTRA_INTENT, intent)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            try {
                return result.await()
            } finally {
                if (pending === result) pending = null
            }
        }
    }
}
