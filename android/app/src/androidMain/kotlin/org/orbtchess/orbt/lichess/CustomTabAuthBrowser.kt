package org.orbtchess.orbt.lichess

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.browser.customtabs.CustomTabsIntent
import kotlinx.coroutines.CompletableDeferred

/**
 * Android's sign-in: Lichess's page in a Custom Tab, and its redirect to the app's custom
 * scheme (`org.orbtchess.orbt://oauth-callback`, the core's and the Apple app's). As AppAuth
 * does, `LichessSignInActivity` opens the tab and waits: the redirect comes back to it through
 * `LichessRedirectActivity`; returning to it without one means the user closed the tab.
 */
class CustomTabAuthBrowser(private val context: Context) : AuthBrowser {
    override suspend fun authenticate(authorizeUrl: (redirectUri: String) -> String): String? {
        val url = authorizeUrl(CORE_REDIRECT_URI)
        val result = CompletableDeferred<String?>()
        LichessSignInActivity.pending?.complete(null)
        LichessSignInActivity.pending = result
        context.startActivity(
            Intent(context, LichessSignInActivity::class.java)
                .putExtra(LichessSignInActivity.EXTRA_URL, url)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        try {
            return result.await()
        } finally {
            if (LichessSignInActivity.pending === result) LichessSignInActivity.pending = null
        }
    }
}

/** Opens a page in a Custom Tab (Analyse on Lichess), as the Swift app's Safari sheet. */
fun openInCustomTab(context: Context, url: String) {
    CustomTabsIntent.Builder().build().apply { intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        .launchUrl(context, Uri.parse(url))
}

/** Opens the Custom Tab and hands the redirect (or null when the tab was closed) to `pending`. */
class LichessSignInActivity : Activity() {
    private var launched = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        launched = savedInstanceState?.getBoolean(LAUNCHED) ?: false
        // The app's process was restarted: nobody waits for this sign-in any more.
        if (pending == null) finish()
    }

    override fun onResume() {
        super.onResume()
        if (isFinishing) return
        if (!launched) {
            val url = intent.getStringExtra(EXTRA_URL) ?: return done(null)
            launched = true
            CustomTabsIntent.Builder().build().launchUrl(this, Uri.parse(url))
        } else {
            done(null)  // back from the tab without a redirect: cancelled
        }
    }

    /** The redirect, from `LichessRedirectActivity` (before `onResume`). */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.data?.let { done(it.toString()) }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(LAUNCHED, launched)
    }

    private fun done(callback: String?) {
        pending?.complete(callback)
        pending = null
        finish()
    }

    companion object {
        const val EXTRA_URL = "url"
        private const val LAUNCHED = "launched"
        /** The sign-in waiting for this activity; one at a time. */
        var pending: CompletableDeferred<String?>? = null
    }
}

/** Receives `org.orbtchess.orbt://oauth-callback?...` and hands it to `LichessSignInActivity`. */
class LichessRedirectActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(
            Intent(this, LichessSignInActivity::class.java)
                .setData(intent.data)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        )
        finish()
    }
}
