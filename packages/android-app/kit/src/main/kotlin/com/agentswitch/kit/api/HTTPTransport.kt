package com.agentswitch.kit.api

import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLHandshakeException
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.resumeWithException
import kotlin.time.Duration
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.ConnectionPool
import okhttp3.Dispatcher
import okhttp3.Headers
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSink

sealed class APIError(message: String) : Exception(message) {
    /** The device token is missing, wrong or revoked (401). */
    data object Unauthorized : APIError("设备令牌无效或已在 Mac 上吊销，请重新配对")

    /** The server's certificate is not the one paired; `seen` is its actual fingerprint. */
    data class PinMismatch(val seen: String?) : APIError("服务器证书与配对时不一致，已拒绝连接")

    /** No saved address answered. */
    data object Unreachable : APIError("无法连接 Mac（局域网与 Tailscale 地址均无响应）")

    /**
     * The server's own text is [detail]; [message] is what the user reads (Swift's `errorDescription`). Not a data
     * class because both would be called `message`; equality is by `status` and `detail`.
     */
    class Http(val status: Int, message: String) : APIError(if (message.isEmpty()) "请求失败（HTTP $status）" else message) {
        val detail: String = message
        override fun equals(other: Any?): Boolean = other is Http && other.status == status && other.detail == detail
        override fun hashCode(): Int = 31 * status + detail.hashCode()
        override fun toString(): String = "Http(status=$status, message=$detail)"
    }

    /** [detail] is the underlying error's text; [message] adds "网络错误：". */
    class Transport(message: String) : APIError("网络错误：$message") {
        val detail: String = message
        override fun equals(other: Any?): Boolean = other is Transport && other.detail == detail
        override fun hashCode(): Int = detail.hashCode()
        override fun toString(): String = "Transport(message=$detail)"
    }

    /** [detail] is the decoder's text; [message] adds "无法解析服务器回复：". */
    class Decoding(message: String) : APIError("无法解析服务器回复：$message") {
        val detail: String = message
        override fun equals(other: Any?): Boolean = other is Decoding && other.detail == detail
        override fun hashCode(): Int = 7 + detail.hashCode()
        override fun toString(): String = "Decoding(message=$detail)"
    }

    /** Worth re-selecting the endpoint and retrying: the network, not the server, failed. */
    val isNetworkFailure: Boolean get() = this is Transport || this == Unreachable
}

/** Swift's `URLRequest`, as much of it as the kit uses. Every request carries its own timeout. */
class HTTPRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray? = null,
    val timeout: Duration,
) {
    fun copy(
        method: String = this.method,
        url: String = this.url,
        headers: Map<String, String> = this.headers,
        body: ByteArray? = this.body,
        timeout: Duration = this.timeout,
    ): HTTPRequest = HTTPRequest(method, url, headers, body, timeout)

    /** A header of the request, its name compared without case. */
    fun header(name: String): String? = headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
}

/** Swift's `HTTPURLResponse`: the status and the headers (several of one name joined with ", "). */
class HTTPResponse(val statusCode: Int, val headers: Map<String, String> = emptyMap()) {
    /** A header of the response, its name compared without case. */
    fun header(name: String): String? = headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
}

/** The only way the kit talks HTTP, so the client, the prober and the event stream are testable with fakes. */
interface HTTPTransport {
    suspend fun send(request: HTTPRequest): Pair<ByteArray, HTTPResponse>

    /**
     * Response head, then the body as it arrives, in chunks of any size. Collecting the flow reads; cancelling it
     * closes the connection.
     */
    suspend fun stream(request: HTTPRequest): Pair<HTTPResponse, Flow<ByteArray>>

    /**
     * `request` with the bytes of `file` as its body, read as they go (not into memory); `progress` from 0 to 1.
     *
     * The default is for a transport with no way to tell how far a body has gone (the tests' fakes): the file read
     * whole, sent once.
     */
    suspend fun upload(request: HTTPRequest, file: File, progress: (Double) -> Unit): Pair<ByteArray, HTTPResponse> {
        val req = request.copy(body = withContext(Dispatchers.IO) { file.readBytes() })
        progress(0.0)
        val reply = send(req)
        progress(1.0)
        return reply
    }
}

/**
 * OkHttp with every connection pinned to the paired certificate fingerprint. One per paired Mac; it serves all of that
 * Mac's addresses because the pin does not depend on the host name.
 *
 * No cache, no cookies, no stored credentials, no redirects followed, and OkHttp's own retry on a failed connection
 * is off (it could send a POST twice). `send` and `upload` are bounded by the request's timeout as a whole; a stream
 * lives for minutes, so there its timeout bounds only the wait for the response head and the caller's own idle guard
 * watches the silence after it. HTTP/2 or HTTP/1.1, whichever the Mac speaks.
 *
 * Connections the Mac has closed. The Mac's service closes a connection 5 seconds after its last request (Node's
 * `keepAliveTimeout`), and OkHttp looks closely at a kept connection only after 10 idle seconds and only before a
 * write: left to itself it hands a request a connection that is closed at the other end, the request fails, and with
 * nothing retried the failure reaches the page (2026-11-11: `Unreachable` for a moment every so often, and each time
 * the app came back from behind; the iPhone's URL session mends this silently). Three things, none of which sends a
 * write twice: a connection nobody uses is let go before the Mac lets it go ([idleKeepMs]); after a silence longer
 * than that — the phone slept, Android froze the app — the kept ones go before the first request (`freshen`); and a
 * read (`GET`, `HEAD`) that fails on its connection is asked once more on a new one (`mayBeStale`).
 */
class PinnedSessionTransport(val fingerprint: String) : HTTPTransport {
    private val delegate = PinnedTrustDelegate(fingerprint)
    private val client: OkHttpClient = defaultClient(delegate)

    companion object {
        /**
         * How many requests one paired Mac may be given at once. A URL session opens at most 4 connections to one host
         * on iOS unless told otherwise, and this one carries everything said to a Mac — its streams too, each holding a
         * connection for as long as it is followed (a live task each, the terminal's, the browser tab's, a file on its
         * way). With four streams open every other request waited for a connection until its own time ran out
         * (2026-11-10; the Mac's side of the same: mac-app `URLSessionStreamTransport.maxConnections`). Here it is the
         * dispatcher's limit per host.
         */
        const val maxConnections = 64

        /** How long a connection nobody uses is kept: less than the 5 seconds the Mac's service keeps its end. */
        const val idleKeepMs = 4_000L

        /** The client of one paired Mac: pinned trust, any host name, nothing stored, nothing retried. */
        fun defaultClient(trust: PinnedTrustDelegate): OkHttpClient {
            val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
            val dispatcher = Dispatcher().apply {
                maxRequestsPerHost = maxConnections
                // A Mac has several addresses and probes go to all of them at once.
                maxRequests = maxConnections * 4
            }
            return OkHttpClient.Builder()
                .sslSocketFactory(context.socketFactory, trust)
                .hostnameVerifier { _, _ -> true }
                .dispatcher(dispatcher)
                .connectionPool(ConnectionPool(maxConnections, idleKeepMs, TimeUnit.MILLISECONDS))
                .cache(null)
                .retryOnConnectionFailure(false)
                .followRedirects(false)
                .followSslRedirects(false)
                // Every request carries its own timeout (see the class comment); the client's own must not cut a
                // longer one short.
                .connectTimeout(0, TimeUnit.MILLISECONDS)
                .readTimeout(0, TimeUnit.MILLISECONDS)
                .writeTimeout(0, TimeUnit.MILLISECONDS)
                .callTimeout(0, TimeUnit.MILLISECONDS)
                .build()
        }

        private val bodyMethods = setOf("POST", "PUT", "PATCH", "PROPPATCH", "REPORT")
    }

    override suspend fun send(request: HTTPRequest): Pair<ByteArray, HTTPResponse> =
        exchange(request, request.body?.toRequestBody(null))

    override suspend fun upload(request: HTTPRequest, file: File, progress: (Double) -> Unit): Pair<ByteArray, HTTPResponse> =
        exchange(request, FileBody(file, progress))

    private val lastRequest = AtomicLong(System.currentTimeMillis())

    /**
     * Before a request: after a silence longer than a connection is kept, the kept ones go now. The pool's own
     * clean-up does that on time while the process runs; it does not while the phone sleeps or Android has the app
     * frozen behind another, and the first request back would be given a connection the Mac closed long ago. (The
     * wall clock, which goes on through sleep; a connection in use — a stream being followed — is not touched.)
     */
    private fun freshen() {
        val now = System.currentTimeMillis()
        val last = lastRequest.getAndSet(now)
        if (now - last > idleKeepMs || now < last) client.connectionPool.evictAll()
    }

    /**
     * Whether a failure may be the connection's — closed by the Mac while it was kept, or dead since the network
     * changed — so that the same request on a new connection may well be answered. Not: a timeout (waiting twice is
     * no help), a refused handshake (the pin), an address that does not answer at all.
     */
    private fun mayBeStale(cause: Throwable, mapped: Throwable): Boolean =
        mapped is APIError.Transport && cause is IOException && cause !is InterruptedIOException && cause !is SSLHandshakeException &&
            cause !is ConnectException && cause !is UnknownHostException && cause !is NoRouteToHostException

    /**
     * One attempt at a stream's response head, the request's timeout bounding the wait. `null` (only with `again`):
     * it failed in the way [mayBeStale] describes and may be asked once more.
     */
    private suspend fun streamHead(ok: Request, request: HTTPRequest, again: Boolean): Pair<Call, Response>? {
        val call = client.newCall(ok)
        val timedOut = AtomicBoolean(false)
        try {
            val response = coroutineScope {
                val timer = launch {
                    delay(request.timeout)
                    timedOut.set(true)
                    call.cancel()
                }
                try { call.await() } finally { timer.cancel() }
            }
            return call to response
        } catch (e: Throwable) {
            currentCoroutineContext().ensureActive()
            val error = mapped(e, call, request)
            if (timedOut.get() && error !is APIError.PinMismatch) throw APIError.Transport("timeout")
            if (again && mayBeStale(e, error)) return null
            throw error
        }
    }

    override suspend fun stream(request: HTTPRequest): Pair<HTTPResponse, Flow<ByteArray>> {
        freshen()
        val ok = okRequest(request, request.body?.toRequestBody(null))
        val (call, response) = streamHead(ok, request, again = ok.method == "GET" || ok.method == "HEAD") ?: run {
            client.connectionPool.evictAll()
            streamHead(ok, request, again = false)!!
        }
        val head = head(response)
        val body = flow {
            response.use { resp ->
                val source = resp.body.source()
                try {
                    cancelling(call) {
                        while (true) {
                            // A chunk ends at a newline or at 4096 bytes, as the iPhone's reader cuts them.
                            val newline = source.indexOf('\n'.code.toByte(), 0, 4096)
                            val chunk = when {
                                newline >= 0 -> source.readByteArray(newline + 1)
                                source.buffer.size >= 4096 -> source.readByteArray(4096)
                                source.buffer.size > 0 -> source.readByteArray()
                                else -> break
                            }
                            emit(chunk)
                        }
                    }
                } catch (e: Throwable) {
                    currentCoroutineContext().ensureActive()
                    throw mapped(e, call, request)
                }
            }
        }.flowOn(Dispatchers.IO)
        return head to body
    }

    private suspend fun exchange(request: HTTPRequest, body: RequestBody?): Pair<ByteArray, HTTPResponse> {
        freshen()
        val ok = okRequest(request, body)
        // A read may be asked once more on a new connection; a write never is (the Mac may have acted on it).
        var again = ok.method == "GET" || ok.method == "HEAD"
        while (true) {
            val call = client.newCall(ok)
            call.timeout().timeout(request.timeout.inWholeMilliseconds.coerceAtLeast(1), TimeUnit.MILLISECONDS)
            try {
                val response = call.await()
                return response.use { resp ->
                    val bytes = cancelling(call) { withContext(Dispatchers.IO) { resp.body.bytes() } }
                    bytes to head(resp)
                }
            } catch (e: Throwable) {
                currentCoroutineContext().ensureActive()
                val error = mapped(e, call, request)
                if (!again || !mayBeStale(e, error)) throw error
                again = false
                client.connectionPool.evictAll()
            }
        }
    }

    private fun okRequest(request: HTTPRequest, body: RequestBody?): Request {
        val method = request.method.uppercase()
        val headers = Headers.Builder().apply { request.headers.forEach { (k, v) -> addUnsafeNonAscii(k, v) } }.build()
        val effectiveBody = when {
            method in bodyMethods -> body ?: ByteArray(0).toRequestBody(null)
            method == "GET" || method == "HEAD" -> null
            else -> body
        }
        return Request.Builder().url(request.url).headers(headers).method(method, effectiveBody).build()
    }

    private fun head(response: Response): HTTPResponse {
        val headers = LinkedHashMap<String, String>()
        for ((name, value) in response.headers) {
            val key = headers.keys.firstOrNull { it.equals(name, ignoreCase = true) }
            if (key == null) headers[name] = value else headers[key] = headers.getValue(key) + ", " + value
        }
        return HTTPResponse(response.code, headers)
    }

    /** A failed handshake after a pin mismatch becomes [APIError.PinMismatch]; other failures become `Transport`. */
    private fun mapped(error: Throwable, call: Call, request: HTTPRequest): Throwable {
        if (error is APIError || error is CancellationException) return error
        val host = call.request().url.host
        delegate.takeMismatch(host)?.let { return APIError.PinMismatch(seen = it.ifEmpty { null }) }
        generateSequence(error) { it.cause }.filterIsInstance<PinnedTrustDelegate.PinRejection>().firstOrNull()?.let {
            return APIError.PinMismatch(seen = it.seen)
        }
        return APIError.Transport(error.message ?: error.javaClass.simpleName)
    }
}

/** Waits for the response head; cancelling the coroutine cancels the call. */
private suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            cont.resume(response) { _, value, _ -> value.close() }
        }
    })
}

/** Runs blocking reads of `call` so that cancelling the coroutine cancels the call (which ends the read). */
private suspend fun <T> cancelling(call: Call, block: suspend () -> T): T = coroutineScope {
    val done = AtomicBoolean(false)
    val guard = launch(start = CoroutineStart.UNDISPATCHED) {
        try { awaitCancellation() } finally { if (!done.get()) call.cancel() }
    }
    try {
        block()
    } finally {
        done.set(true)
        guard.cancel()
    }
}

/** The file as a request body, read as it goes; how far it has gone told to `progress`. */
private class FileBody(private val file: File, private val progress: (Double) -> Unit) : RequestBody() {
    override fun contentType(): MediaType? = null
    override fun contentLength(): Long = file.length()

    override fun writeTo(sink: BufferedSink) {
        val total = contentLength()
        var sent = 0L
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                sink.write(buffer, 0, n)
                sink.emit()
                sent += n
                if (total > 0) progress(minOf(1.0, sent.toDouble() / total.toDouble()))
            }
        }
    }
}
