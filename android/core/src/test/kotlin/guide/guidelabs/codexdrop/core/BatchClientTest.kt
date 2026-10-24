package guide.guidelabs.codexdrop.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer

internal const val TEST_ID = "12345678-1234-1234-1234-123456789abc"
internal fun png(width: Int = 1, height: Int = 1, size: Int = 33): ByteArray {
    val bytes = ByteArray(size)
    ByteBuffer.wrap(bytes).put(byteArrayOf(-119,80,78,71,13,10,26,10)).putInt(13).put("IHDR".toByteArray()).putInt(width).putInt(height).put(byteArrayOf(8,6,0,0,0)).putInt(0)
    return bytes
}
internal fun jobJson(id: String = TEST_ID, state: String = "uploading", count: Int = 2): String {
    val statuses = if (state == "uncertain") listOf("verified", "uncertain") else List(count) { "verified" }
    val items = statuses.mapIndexed { i, s -> """{"index":$i,"status":"$s","pasteAttempted":true}""" }.joinToString(",")
    val result = if (state in setOf("verified", "uncertain")) """{"verifiedCount":${statuses.count { it == "verified" }},"totalCount":$count,"items":[$items]}""" else "null"
    return """{"id":"$id","state":"$state","result":$result}"""
}
private class RecordingTransport(var terminal: String = "verified") : Transport {
    val requests = mutableListOf<HttpRequest>()
    var currentId = TEST_ID
    var count = 2
    override suspend fun execute(request: HttpRequest): HttpReply {
        requests += request
        if (request.path == "v1/batches") {
            currentId = request.requestId!!
            count = Regex("[0-9]+").find(request.body!!.decodeToString())!!.value.toInt()
        }
        val state = if (request.path.endsWith("/commit")) terminal else "uploading"
        return HttpReply(202, """{"received":true,"job":${jobJson(currentId, state, count)}}""".toByteArray())
    }
}
class BatchClientTest {
    @Test fun originalBytesAreUploadedUnchangedWithoutLocalFormatOrPixelChanges() = runBlocking {
        val originals = listOf(
            png(3024, 4032), png(40_000, 40_000),
            byteArrayOf(-1,-40,-1,-31) + "Exif orientation=6 ICC original metadata".toByteArray(),
            "GIF89a original animated frames".toByteArray(),
            "RIFF original WEBP metadata".toByteArray(),
            "\u0000\u0000\u0000\u0018ftypheic original HEIC bytes".toByteArray(),
        )
        val transport = RecordingTransport()
        assertTrue(BatchClient(transport).attach(originals.size, TEST_ID, prepare = { originals[it] }).allVerified(originals.size))
        val uploads = transport.requests.filter { "/images/" in it.path }
        assertEquals(originals.size, uploads.size)
        originals.forEachIndexed { index, bytes ->
            assertArrayEquals(bytes, uploads[index].body)
            assertEquals("application/octet-stream", uploads[index].contentType)
        }
    }
    @Test fun unsupportedHeicReplyIsExplainedWithoutRetryOrCommit() {
        val message = "Codex does not accept HEIC/HEIF as image inputs. Share a JPEG, PNG, GIF or WebP instead. In Photos, use Automatic or Most Compatible."
        val requests = mutableListOf<HttpRequest>()
        var persisted = false
        var prepared = 0
        val transport = Transport { request ->
            requests += request
            if (request.path.endsWith("/images/1")) HttpReply(400, """{"error":"unsupported_image_format","message":"$message"}""".toByteArray())
            else HttpReply(202, """{"received":true,"job":${jobJson(count = 3)}}""".toByteArray())
        }
        val failure = assertThrows(DropFailure::class.java) { runBlocking {
            BatchClient(transport).attach(3, TEST_ID, prepare = { prepared++;png() }, beforeCommit = { persisted = true })
        } }
        assertEquals(message, failure.message)
        assertFalse(failure.mayBeAttached)
        assertEquals(2, prepared)
        assertEquals(2, requests.count { "/images/" in it.path })
        assertEquals(1, requests.count { it.path.endsWith("/images/1") })
        assertFalse(persisted)
        assertFalse(requests.any { it.path.endsWith("/commit") })
    }
    @Test fun unsupportedFormatFallbackIsClearWhileUnrecognizedErrorsStayGeneric() {
        val cases = listOf(
            """{"error":"unsupported_image_format","message":"   "}""" to "Codex accepts JPEG, PNG, GIF and WebP image inputs. Share one of those formats instead.",
            """{"error":"unsupported_image_format","message":"line\nbreak"}""" to "Codex accepts JPEG, PNG, GIF and WebP image inputs. Share one of those formats instead.",
            """{"error":"unsupported_image_format","message":"${"x".repeat(513)}"}""" to "Codex accepts JPEG, PNG, GIF and WebP image inputs. Share one of those formats instead.",
            """{"error":"unsupported_image_format"}""" to "Codex accepts JPEG, PNG, GIF and WebP image inputs. Share one of those formats instead.",
            """{"error":"unsupported_image_format","message":9}""" to "Codex accepts JPEG, PNG, GIF and WebP image inputs. Share one of those formats instead.",
            """{"error":"unknown","message":"arbitrary server copy"}""" to "The Mac refused the request. Check the receiver before sharing again. No automatic retry.",
            "not JSON" to "The Mac refused the request. Check the receiver before sharing again. No automatic retry.",
        )
        for ((body, expected) in cases) {
            val transport = Transport { request ->
                if ("/images/" in request.path) HttpReply(400, body.toByteArray())
                else HttpReply(202, """{"received":true,"job":${jobJson(count = 1)}}""".toByteArray())
            }
            val failure = assertThrows(DropFailure::class.java) { runBlocking { BatchClient(transport).attach(1, TEST_ID, prepare = { png() }) } }
            assertEquals(expected, failure.message)
            assertFalse(failure.mayBeAttached)
        }
    }
    @Test fun uploadsInOrderThenCommitsOnceAfterDurableReceipt() = runBlocking {
        val transport = RecordingTransport()
        var persisted = false
        val result = BatchClient(transport).attach(2, TEST_ID, prepare = { png() }, beforeCommit = {
            assertFalse(transport.requests.any { it.path.endsWith("/commit") })
            assertEquals(2, transport.requests.count { "/images/" in it.path })
            persisted = true
        })
        assertTrue(persisted)
        assertTrue(result.allVerified(2))
        assertEquals(listOf("v1/batches", "v1/batches/$TEST_ID/images/0", "v1/batches/$TEST_ID/images/1", "v1/batches/$TEST_ID/commit"), transport.requests.map { it.path })
        assertEquals(TEST_ID, transport.requests.first().requestId)
        assertEquals("application/octet-stream", transport.requests[1].contentType)
    }
    @Test fun cancelledPreparationNeverCommits() {
        val transport = RecordingTransport()
        assertThrows(CancellationException::class.java) {
            runBlocking { BatchClient(transport).attach(2, TEST_ID, prepare = { if (it == 1) throw CancellationException(); png() }) }
        }
        assertFalse(transport.requests.any { it.path.endsWith("/commit") })
    }
    @Test fun failedReceiptPersistenceNeverCommits() {
        val transport = RecordingTransport()
        assertThrows(DropFailure::class.java) {
            runBlocking { BatchClient(transport).attach(2, TEST_ID, prepare = { png() }, beforeCommit = { error("fixture disk unavailable") }) }
        }
        assertFalse(transport.requests.any { it.path.endsWith("/commit") })
    }
    @Test fun countAndImageLimitsAreEnforcedBeforeCommit() {
        for (count in listOf(0, 11)) {
            val transport = RecordingTransport()
            assertThrows(DropFailure::class.java) { runBlocking { BatchClient(transport).attach(count, TEST_ID, prepare = { png() }) } }
            assertTrue(transport.requests.isEmpty())
        }
        for (bytes in listOf(ByteArray(0), png(size = 50 * 1024 * 1024 + 1))) {
            val transport = RecordingTransport()
            assertThrows(DropFailure::class.java) { runBlocking { BatchClient(transport).attach(1, TEST_ID, prepare = { bytes }) } }
            assertFalse(transport.requests.any { "/images/" in it.path || it.path.endsWith("/commit") })
        }
    }
    @Test fun totalByteLimitStopsBeforeTheExtraImageOrCommit() {
        val transport = RecordingTransport()
        assertThrows(DropFailure::class.java) { runBlocking { BatchClient(transport).attach(3, TEST_ID, prepare = { png(size = 50 * 1024 * 1024) }) } }
        assertEquals(2, transport.requests.count { "/images/" in it.path })
        assertFalse(transport.requests.any { it.path.endsWith("/commit") })
    }
    @Test fun confirmationTimeoutIsUncertainAndDoesNotResubmit() {
        val transport = RecordingTransport(terminal = "queued")
        val error = assertThrows(DropFailure::class.java) { runBlocking { BatchClient(transport, pollTimeoutMillis = 0).attach(2, TEST_ID, prepare = { png() }) } }
        assertTrue(error.mayBeAttached)
        assertEquals(1, transport.requests.count { it.path.endsWith("/commit") })
    }
    @Test fun anOldUncertainShareDoesNotBlockAFreshShare() = runBlocking {
        val transport = RecordingTransport(terminal = "uncertain")
        val client = BatchClient(transport)
        assertFalse(client.attach(2, TEST_ID, prepare = { png() }).allVerified(2))
        transport.terminal = "verified"
        assertTrue(client.attach(2, "22345678-1234-1234-1234-123456789abc", prepare = { png() }).allVerified(2))
        assertEquals(2, transport.requests.count { it.path.endsWith("/commit") })
    }
    @Test fun malformedOrWrongReceiptsCannotReportSuccess() {
        for (raw in listOf(jobJson(state = "verified").replace("\"index\":1", "\"index\":0"), jobJson(state = "verified").replace("\"verifiedCount\":2", "\"verifiedCount\":1"), jobJson(id = "22345678-1234-1234-1234-123456789abc", state = "verified"))) {
            var commits = 0
            val transport = Transport { request ->
                val reply = if (request.path.endsWith("/commit")) { commits++; raw } else jobJson()
                HttpReply(200, """{"received":true,"job":$reply}""".toByteArray())
            }
            val error = assertThrows(DropFailure::class.java) { runBlocking { BatchClient(transport).attach(2, TEST_ID, prepare = { png() }) } }
            assertTrue(error.mayBeAttached)
            assertEquals(1, commits)
        }
    }
}
