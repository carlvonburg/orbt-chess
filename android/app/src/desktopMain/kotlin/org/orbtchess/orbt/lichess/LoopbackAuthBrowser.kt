package org.orbtchess.orbt.lichess

import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.net.InetAddress
import java.net.InetSocketAddress

/**
 * The desktop's sign-in: Lichess's page in the default browser, and its redirect to a server
 * on the loopback address (RFC 8252's loopback redirect; a desktop app has no custom scheme
 * it can count on). There is no way to tell the user closed the tab: the wait ends after
 * `timeoutMs`, or when the caller's coroutine is cancelled.
 */
class LoopbackAuthBrowser(
    private val openUrl: (String) -> Unit,
    private val timeoutMs: Long = 5 * 60_000,
) : AuthBrowser {
    override suspend fun authenticate(authorizeUrl: (redirectUri: String) -> String): String? {
        val server = HttpServer.create(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 0)
        val redirectUri = "http://127.0.0.1:${server.address.port}/"
        val callback = CompletableDeferred<String>()
        server.createContext("/") { exchange ->
            val query = exchange.requestURI.rawQuery
            // Only the redirect carries a state; the browser may also ask for a favicon.
            val redirect = exchange.requestURI.rawPath == "/" && query != null && "state=" in query
            val page = (if (redirect) DONE_PAGE else "Not found").toByteArray()
            exchange.responseHeaders.add("Content-Type", "text/html; charset=utf-8")
            exchange.sendResponseHeaders(if (redirect) 200 else 404, page.size.toLong())
            exchange.responseBody.use { it.write(page) }
            if (redirect) callback.complete("$redirectUri?$query")
        }
        server.start()
        try {
            openUrl(authorizeUrl(redirectUri))
            return withTimeoutOrNull(timeoutMs) { callback.await() }
        } finally {
            server.stop(0)
        }
    }

    private companion object {
        const val DONE_PAGE = "<!doctype html><meta charset=utf-8><title>ORBT Chess</title>" +
            "<body style=\"font-family:system-ui;margin:3em\">" +
            "<p>You can close this tab and return to ORBT Chess.</p>"
    }
}
