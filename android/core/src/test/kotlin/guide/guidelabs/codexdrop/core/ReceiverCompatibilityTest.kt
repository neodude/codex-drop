package guide.guidelabs.codexdrop.core

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import java.io.File
import java.net.InetAddress
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit

class ReceiverCompatibilityTest {
    @get:Rule val temporary = TemporaryFolder()
    @Test fun stagedBatchAndReceiptRoundTripThroughTheExistingPythonReceiver() = runBlocking {
        val root = File(System.getProperty("codexDrop.repoRoot"))
        val script = File(root, "android/core/src/test/resources/receiver_fixture.py")
        val audit = temporary.newFile("receiver-audit.json")
        val builder = ProcessBuilder("python3", script.absolutePath, root.absolutePath).redirectError(ProcessBuilder.Redirect.INHERIT)
        builder.environment()["CODEX_DROP_FIXTURE_AUDIT"] = audit.absolutePath
        val process = builder.start()
        val originals = listOf(
            javaClass.getResourceAsStream("/synthetic-video.mp4")!!.use { it.readBytes() },
            File(root, "test-image.png").readBytes(),
            javaClass.getResourceAsStream("/synthetic-video.mov")!!.use { it.readBytes() },
        )
        val mixedId = UUID.randomUUID().toString()
        try {
            val raw = process.inputStream.bufferedReader().readLine() ?: error("Isolated receiver failed to start")
            val config = StrictJson.objectValue(raw.toByteArray())
            val pairing = Pairing.parse(config.string("pairing"))
            PinnedHttpsTransport(pairing, Endpoint(listOf(InetAddress.getLoopbackAddress()), config.int("port"))).use { transport ->
                val client = BatchClient(transport)
                client.checkConnection()
                val id = UUID.randomUUID().toString()
                val image = File(root, "test-image.png").readBytes()
                var savedBeforeCommit = false
                val result = client.attach(3, id, prepare = { image }, beforeCommit = { savedBeforeCommit = true })
                assertTrue(savedBeforeCommit)
                assertTrue(result.allVerified(3))
                assertEquals(3, client.lookup(id).verifiedCount)

                val mixed = client.attach(originals.size, mixedId, prepare = { originals[it] })
                assertTrue(mixed.allVerified(originals.size))
                assertEquals(originals.size, client.lookup(mixedId).verifiedCount)

                // A valid HEIC remains unchanged on the phone and must be refused as an image by the receiver.
                val rejectedId = UUID.randomUUID().toString()
                val paths = mutableListOf<String>()
                val rejectingClient = BatchClient(Transport { request -> paths += request.path;transport.execute(request) })
                val heic = File(root, "android/app/src/androidTest/resources/synthetic.heic").readBytes()
                var remembered = false
                val failure = assertThrows(DropFailure::class.java) { runBlocking {
                    rejectingClient.attach(1, rejectedId, prepare = { heic }, beforeCommit = { remembered = true })
                } }
                assertTrue(failure.message!!.contains("HEIC/HEIF"))
                assertTrue(failure.message!!.contains("JPEG, PNG, GIF or WebP"))
                assertFalse(failure.mayBeAttached)
                assertFalse(remembered)
                assertEquals(1, paths.count { "/images/" in it })
                assertFalse(paths.any { it.endsWith("/commit") })
                assertEquals("uploading", client.lookup(rejectedId).state)
            }
        } finally {
            process.outputStream.write("stop\n".toByteArray()); process.outputStream.flush(); process.outputStream.close()
            if (!process.waitFor(10, TimeUnit.SECONDS)) { process.destroyForcibly(); error("Isolated receiver fixture did not stop") }
            assertEquals(0, process.exitValue())
        }
        val report = StrictJson.objectValue(audit.readBytes())
        val deliveries = report["deliveries"] as List<*>
        val mixed = deliveries.map { it as Map<*, *> }.single { it["id"] == mixedId }
        assertEquals(listOf(0, 1, 2), (mixed["indices"] as List<*>).map { (it as Number).toInt() })
        val hashes = originals.map { bytes -> MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) } }
        assertEquals("Receiver stored complete MP4/image/MOV originals in selection order", hashes, mixed["sha256"])
    }
}
