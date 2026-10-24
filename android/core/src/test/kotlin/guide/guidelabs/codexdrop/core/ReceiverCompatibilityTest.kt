package guide.guidelabs.codexdrop.core

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.TimeUnit

class ReceiverCompatibilityTest {
    @Test fun stagedBatchAndReceiptRoundTripThroughTheExistingPythonReceiver() = runBlocking {
        val root = File(System.getProperty("codexDrop.repoRoot"))
        val script = File(root, "android/core/src/test/resources/receiver_fixture.py")
        val process = ProcessBuilder("python3", script.absolutePath, root.absolutePath).redirectError(ProcessBuilder.Redirect.INHERIT).start()
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
    }
}
