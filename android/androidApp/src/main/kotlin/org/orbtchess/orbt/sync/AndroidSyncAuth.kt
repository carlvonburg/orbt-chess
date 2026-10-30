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
import org.orbtchess.orbt.core.SignInException
import org.orbtchess.orbt.core.dropboxAccountRequest
import org.orbtchess.orbt.core.dropboxAuthorizeUrl
import org.orbtchess.orbt.core.dropboxParseAccount
import org.orbtchess.orbt.core.dropboxParseToken
import org.orbtchess.orbt.core.dropboxRedirectUri
import org.orbtchess.orbt.core.dropboxTokenRequest
import org.orbtchess.orbt.core.oauthParseRedirect
import org.orbtchess.orbt.core.oauthRandomString
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
        // Dropbox: the core revoked the tokens on the server (`SyncService.signOut`). Drive:
        // the system's cached token is dropped.
        if (provider == SyncProvider.Drive) credentials?.accessToken?.let { clearDriveToken(it) }
    }

    // MARK: Dropbox

    /** PKCE in a Custom Tab; the requests and the answers are the core's. */
    private suspend fun dropboxSignIn(): SyncCredentials? {
        if (dropboxAppKey.isEmpty()) throw SyncSignInException("This build has no Dropbox app key.")
        val verifier = oauthRandomString(randomBytes(64))
        val state = oauthRandomString(randomBytes(32))
        val redirectUri = dropboxRedirectUri()
        val callback = CustomTabAuthBrowser(context, redirectUri).authenticate { uri ->
            dropboxAuthorizeUrl(dropboxAppKey, verifier, state, uri)
        } ?: return null
        try {
            val code = oauthParseRedirect(callback, state) ?: return null  // the user declined
            val response = Http.send(dropboxTokenRequest(dropboxAppKey, code, verifier, redirectUri))
                ?: throw SyncSignInException("Could not reach Dropbox.")
            val signIn = dropboxParseToken(response, System.currentTimeMillis())
            val account = Http.send(dropboxAccountRequest(signIn.accessToken))?.let(::dropboxParseAccount)
            return SyncCredentials(
                accessToken = signIn.accessToken,
                expiresAt = signIn.expiresAt,
                refreshToken = signIn.refreshToken,
                account = account,
            )
        } catch (e: SignInException) {
            throw SyncSignInException((e as? SignInException.Failed)?.reason ?: e.message ?: "Dropbox sign-in failed.")
        }
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
            // The system does not say when it expires: the core uses it until Google answers
            // 401, then asks for a new one (`AuthNeed.TOKEN`, `token`).
            expiresAt = null,
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
