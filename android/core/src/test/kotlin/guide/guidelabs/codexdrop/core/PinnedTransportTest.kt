package guide.guidelabs.codexdrop.core

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.net.InetAddress
import java.security.MessageDigest

class PinnedTransportTest {
    private fun pairing(cert: HeldCertificate) = Pairing("CodexShot-$TEST_ID", MessageDigest.getInstance("SHA-256").digest(cert.certificate.encoded).joinToString("") { "%02x".format(it) }, "b".repeat(43))
    @Test fun exactPairedCertificateWorksWithoutPublicCaOrMatchingHostname() = runBlocking {
        val cert = HeldCertificate.Builder().commonName("Fixture Mac").build()
        MockWebServer().use { server ->
            server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory(), false)
            server.enqueue(MockResponse().setBody("{}")); server.start()
            PinnedHttpsTransport(pairing(cert), Endpoint(listOf(InetAddress.getLoopbackAddress()), server.port)).use { client ->
                assertEquals(200, client.execute(HttpRequest("v1/jobs/$TEST_ID")).statusCode)
                assertEquals("Bearer " + "b".repeat(43), server.takeRequest().getHeader("Authorization"))
            }
        }
    }
    @Test fun fiftyMiBImageUploadsOnceOverPinnedConnectionEvenWhenServerRequestsRetry() = runBlocking {
        val cert = HeldCertificate.Builder().commonName("Fixture Mac").build()
        MockWebServer().use { server ->
            server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory(), false)
            server.bodyLimit = 0
            server.enqueue(MockResponse().setResponseCode(503).addHeader("Retry-After", "0"))
            server.enqueue(MockResponse().setBody("unexpected replay"));server.start()
            PinnedHttpsTransport(pairing(cert), Endpoint(listOf(InetAddress.getLoopbackAddress()), server.port)).use { client ->
                val request = HttpRequest("v1/batches/$TEST_ID/images/0", png(size = MAX_IMAGE_BYTES), "application/octet-stream")
                assertEquals(503, client.execute(request).statusCode)
                val recorded = server.takeRequest()
                assertEquals(MAX_IMAGE_BYTES.toLong(), recorded.bodySize)
                assertEquals("Bearer " + "b".repeat(43), recorded.getHeader("Authorization"))
                assertEquals(1, server.requestCount)
            }
        }
    }
    @Test fun changedCertificateNeverReceivesTheBearerToken() {
        val paired = HeldCertificate.Builder().commonName("Paired Mac").build()
        val stranger = HeldCertificate.Builder().commonName("Spoofed Mac").build()
        MockWebServer().use { server ->
            server.useHttps(HandshakeCertificates.Builder().heldCertificate(stranger).build().sslSocketFactory(), false);server.start()
            PinnedHttpsTransport(pairing(paired), Endpoint(listOf(InetAddress.getLoopbackAddress()), server.port)).use { client ->
                assertThrows(IOException::class.java) { runBlocking { client.execute(HttpRequest("v1/jobs/$TEST_ID")) } }
                assertEquals(0, server.requestCount)
            }
        }
    }
    @Test fun redirectsAreReturnedWithoutFollowingThem() = runBlocking {
        val cert = HeldCertificate.Builder().commonName("Fixture Mac").build()
        MockWebServer().use { server ->
            server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory(), false)
            server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", "https://other.invalid/steal"));server.start()
            PinnedHttpsTransport(pairing(cert), Endpoint(listOf(InetAddress.getLoopbackAddress()), server.port)).use { client ->
                assertEquals(302, client.execute(HttpRequest("v1/jobs/$TEST_ID")).statusCode)
                assertEquals(1, server.requestCount)
            }
        }
    }
    @Test fun boundedChunkedRepliesCanEndBeforeTheLimit() = runBlocking {
        val cert = HeldCertificate.Builder().commonName("Fixture Mac").build()
        MockWebServer().use { server ->
            server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory(), false)
            server.enqueue(MockResponse().setChunkedBody("{}", 1));server.start()
            PinnedHttpsTransport(pairing(cert), Endpoint(listOf(InetAddress.getLoopbackAddress()), server.port)).use { client ->
                assertEquals("{}", client.execute(HttpRequest("v1/jobs/$TEST_ID")).body.decodeToString())
            }
        }
    }
    @Test fun repliesAreBounded() {
        val cert = HeldCertificate.Builder().commonName("Fixture Mac").build()
        MockWebServer().use { server ->
            server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory(), false)
            server.enqueue(MockResponse().setBody("x".repeat(65_537)));server.start()
            PinnedHttpsTransport(pairing(cert), Endpoint(listOf(InetAddress.getLoopbackAddress()), server.port)).use { client ->
                assertThrows(IOException::class.java) { runBlocking { client.execute(HttpRequest("v1/jobs/$TEST_ID")) } }
            }
        }
    }
    @Test fun serviceUnavailableNeverReplaysACommitBody() = runBlocking {
        val cert = HeldCertificate.Builder().commonName("Fixture Mac").build()
        MockWebServer().use { server ->
            server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory(), false)
            server.enqueue(MockResponse().setResponseCode(503).addHeader("Retry-After", "0"))
            server.enqueue(MockResponse().setBody("unexpected replay"));server.start()
            PinnedHttpsTransport(pairing(cert), Endpoint(listOf(InetAddress.getLoopbackAddress()), server.port)).use { client ->
                assertEquals(503, client.execute(HttpRequest("v1/batches/$TEST_ID/commit", "{}".toByteArray())).statusCode)
                assertEquals(1, server.requestCount)
            }
        }
    }
    @Test fun closedTransportCannotSubmitAgain() {
        val cert = HeldCertificate.Builder().commonName("Fixture Mac").build()
        val transport = PinnedHttpsTransport(pairing(cert),Endpoint(listOf(InetAddress.getLoopbackAddress()),9))
        transport.close();transport.close()
        assertThrows(IOException::class.java) { runBlocking { transport.execute(HttpRequest("v1/batches", "{}".toByteArray(), requestId = TEST_ID)) } }
    }
}
