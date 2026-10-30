package org.orbtchess.orbt.platform

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.orbtchess.orbt.core.Header
import org.orbtchess.orbt.core.HttpMethod
import org.orbtchess.orbt.core.HttpRequest
import org.orbtchess.orbt.core.HttpResponse
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Sends the requests the core describes and hands back what the server answered. The core
 * builds every request (URL, headers, body) and reads every answer (`apple/ORBT/Lichess/HTTP.swift`).
 */
object Http {
    private val client = OkHttpClient()

    /** Null when there was no answer (offline, timeout, a URL OkHttp rejects). */
    suspend fun send(request: HttpRequest): HttpResponse? = withContext(Dispatchers.IO) {
        val builder = try {
            Request.Builder().url(request.url)
        } catch (_: IllegalArgumentException) {
            return@withContext null
        }
        val headers = Headers.Builder()
        for (header in request.headers) headers.add(header.name, header.value)
        builder.headers(headers.build())
        val body = request.body.takeIf { it.isNotEmpty() }?.toRequestBody()
        when (request.method) {
            HttpMethod.GET -> builder.get()
            HttpMethod.POST -> builder.post(body ?: ByteArray(0).toRequestBody())
            HttpMethod.PATCH -> builder.patch(body ?: ByteArray(0).toRequestBody())
            HttpMethod.DELETE -> if (body != null) builder.delete(body) else builder.delete()
        }
        // The read timeout too: Dropbox's long poll answers after minutes, not OkHttp's 10 s.
        val call = request.timeoutSecs?.let { secs ->
            client.newBuilder()
                .callTimeout(secs.toLong(), TimeUnit.SECONDS)
                .readTimeout(secs.toLong(), TimeUnit.SECONDS)
                .build()
        } ?: client
        try {
            call.newCall(builder.build()).execute().use { response ->
                HttpResponse(
                    status = response.code.toUShort(),
                    headers = response.headers.map { (name, value) -> Header(name, value) },
                    body = response.body?.bytes() ?: ByteArray(0),
                )
            }
        } catch (_: IOException) {
            null
        }
    }
}
