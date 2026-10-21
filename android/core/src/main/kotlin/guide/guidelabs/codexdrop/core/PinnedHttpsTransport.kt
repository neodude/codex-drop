package guide.guidelabs.codexdrop.core

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okio.Buffer
import okio.BufferedSink
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.Proxy
import java.net.UnknownHostException
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.*
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Keep InetAddress objects intact, including the scope on IPv6 link-local addresses. */
data class Endpoint(val addresses: List<InetAddress>, val port: Int) {
    init { require(addresses.isNotEmpty() && port in 1..65535) }
}

class PinnedHttpsTransport(pairing: Pairing, endpoint: Endpoint) : Transport, Closeable {
    private val host = "codex-drop-paired.invalid" // Resolved only by this client's scoped DNS below.
    private val base = HttpUrl.Builder().scheme("https").host(host).port(endpoint.port).build()
    private val token = pairing.token
    private val client: OkHttpClient
    private val closed = AtomicBoolean(false)
    init {
        val expected = pairing.pin.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        fun matches(certificate: X509Certificate): Boolean = MessageDigest.isEqual(expected, MessageDigest.getInstance("SHA-256").digest(certificate.encoded))
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) { throw CertificateException("Client certificates are not supported") }
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                val leaf = chain?.firstOrNull() ?: throw CertificateException("Missing paired certificate")
                leaf.checkValidity()
                if (!matches(leaf)) throw CertificateException("Paired certificate mismatch")
            }
        }
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }
        client = OkHttpClient.Builder()
            .sslSocketFactory(tls.socketFactory, trust)
            // The scanned certificate is the server identity; mDNS names/IPs are not trusted identities.
            .hostnameVerifier { _, session -> runCatching { matches(session.peerCertificates.first() as X509Certificate) }.getOrDefault(false) }
            .dns(object : Dns { override fun lookup(hostname: String): List<InetAddress> = if (hostname == host) endpoint.addresses else throw UnknownHostException("Unpaired host") })
            .proxy(Proxy.NO_PROXY)
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .cookieJar(CookieJar.NO_COOKIES).cache(null)
            .connectionSpecs(listOf(ConnectionSpec.MODERN_TLS))
            .protocols(listOf(Protocol.HTTP_1_1)) // The paired Python receiver speaks HTTP/1.1.
            .connectTimeout(5, TimeUnit.SECONDS).readTimeout(10, TimeUnit.SECONDS).writeTimeout(20, TimeUnit.SECONDS)
            .callTimeout(25, TimeUnit.SECONDS).build()
    }
    override suspend fun execute(request: HttpRequest): HttpReply {
        if (closed.get()) throw IOException("Receiver connection is closed")
        require(request.path.matches(Regex("v1/(batches|jobs)(/[0-9a-f-]{36})?(/(images/[0-9]|commit))?")))
        val builder = Request.Builder().url(base.newBuilder().encodedPath("/" + request.path).build())
            .header("Authorization", "Bearer $token").header("Cache-Control", "no-store")
        request.body?.let {
            val bytes = it.toRequestBody(request.contentType.toMediaType())
            // Also prevent HTTP follow-ups (e.g. 503 Retry-After: 0), not just connection retries.
            builder.post(object : RequestBody() {
                override fun contentType() = bytes.contentType()
                override fun contentLength() = bytes.contentLength()
                override fun isOneShot() = true
                override fun writeTo(sink: BufferedSink) = bytes.writeTo(sink)
            })
        }
        request.requestId?.let { builder.header("X-Request-ID", it) }
        val call = client.newCall(builder.build())
        return suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) { if (!continuation.isCancelled) continuation.resumeWithException(e) }
                override fun onResponse(call: Call, response: Response) {
                    try {
                        response.use {
                            val body = response.body ?: throw IOException("Missing receiver reply")
                            if (body.contentLength() > 65_536) throw IOException("Receiver reply exceeds limit")
                            val source = body.source()
                            val buffer = Buffer()
                            while (buffer.size <= 65_536 && source.read(buffer, minOf(8192L, 65_537 - buffer.size)) != -1L) { /* bounded, including chunked replies */ }
                            if (buffer.size > 65_536) throw IOException("Receiver reply exceeds limit")
                            val bytes = buffer.readByteArray()
                            if (!continuation.isCancelled) continuation.resume(HttpReply(response.code, bytes))
                        }
                    } catch (error: Exception) { if (!continuation.isCancelled) continuation.resumeWithException(error) }
                }
            })
        }
    }
    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        // SSLSocket.close may write close_notify. Never run it on the caller's UI thread.
        val executor = client.dispatcher.executorService
        executor.execute {
            client.dispatcher.cancelAll()
            client.connectionPool.evictAll()
        }
        executor.shutdown()
    }
}
