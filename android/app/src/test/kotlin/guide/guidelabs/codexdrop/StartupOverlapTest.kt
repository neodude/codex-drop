package guide.guidelabs.codexdrop

import guide.guidelabs.codexdrop.core.*
import guide.guidelabs.codexdrop.platform.PendingReceipt
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.*
import org.junit.Assert.*

@OptIn(ExperimentalCoroutinesApi::class)
class StartupOverlapTest {
    private val dispatcher = StandardTestDispatcher()
    @Before fun setUp() { Dispatchers.setMain(dispatcher) }
    @After fun tearDown() { Dispatchers.resetMain() }

    private class Gateway : DropGateway {
        override val slot = TransferSlot()
        val connectGate = CompletableDeferred<Unit>()
        val prepareGate = CompletableDeferred<Unit>()
        val uploadGate = CompletableDeferred<Unit>()
        val events = mutableListOf<String>()
        val uploads = mutableListOf<Pair<Int, ByteArray>>()
        val originals = listOf(byteArrayOf(1, 2, 3), byteArrayOf(4, 5), byteArrayOf(6))
        var connectFailure: Exception? = null
        var prepareFailure: Exception? = null
        var submissions = 0
        var commits = 0
        var closes = 0
        var stored: PendingReceipt? = null
        override suspend fun pairing() = Pairing("CodexShot-12345678-1234-1234-1234-123456789abc", "a".repeat(64), "b".repeat(43))
        override suspend fun remember(receipt: PendingReceipt) { stored = receipt }
        override suspend fun receipt(id: String) = stored?.takeIf { it.id == id }
        override suspend fun prepare(source: String): ByteArray {
            events += "prepare:$source"
            try {
                if (source == "0") { prepareGate.await(); prepareFailure?.let { throw it } }
                events += "prepared:$source"
                return originals[source.toInt()]
            } catch (cancelled: CancellationException) {
                events += "prepare-cancelled:$source"
                throw cancelled
            }
        }
        override suspend fun connect(pairing: Pairing): DropConnection {
            events += "connect"
            try { connectGate.await() }
            catch (cancelled: CancellationException) { events += "connect-cancelled"; throw cancelled }
            connectFailure?.let { throw it }
            events += "connected"
            var id = ""
            var count = 0
            val transport = Transport { request ->
                if (request.path == "v1/batches") {
                    submissions++
                    id = request.requestId!!
                    count = Regex("[0-9]+").find(request.body!!.decodeToString())!!.value.toInt()
                }
                if ("/images/" in request.path) {
                    val index = request.path.substringAfterLast('/').toInt()
                    uploads += index to request.body!!
                    events += "upload:$index"
                    if (index == 0) uploadGate.await()
                }
                val committing = request.path.endsWith("/commit")
                if (committing) { assertEquals(id, stored?.id); commits++ }
                val state = if (committing) "verified" else "uploading"
                val items = (0 until count).joinToString(",") { """{"index":$it,"status":"verified"}""" }
                val result = if (committing) """{"verifiedCount":$count,"totalCount":$count,"items":[$items]}""" else "null"
                HttpReply(202, """{"received":true,"job":{"id":"$id","state":"$state","result":$result}}""".toByteArray())
            }
            return object : DropConnection {
                override val client = BatchClient(transport)
                override fun close() { closes++ }
            }
        }
        fun assertReleased() { assertTrue(slot.acquire()); slot.release() }
    }

    // Regressions caught: serial startup, early batch submission, image-zero rereads,
    // reordered/modified uploads, and accidentally introducing per-image lookahead.
    @Test fun firstPreparationOverlapsConnectionThenUploadsRemainSequential() = runTest(dispatcher) {
        val gateway = Gateway()
        val model = ShareViewModel(gateway)
        try {
            model.start(listOf("0", "1", "2")); runCurrent()
            assertTrue(gateway.events.contains("connect"))
            assertTrue("First image must start while connection is pending", gateway.events.contains("prepare:0"))
            assertEquals(0, gateway.submissions)
            gateway.prepareGate.complete(Unit); runCurrent()
            assertTrue(gateway.events.contains("prepared:0"))
            assertEquals(0, gateway.submissions)
            gateway.connectGate.complete(Unit); runCurrent()
            assertEquals(1, gateway.submissions)
            assertEquals(listOf("prepare:0"), gateway.events.filter { it.startsWith("prepare:") })
            assertEquals(listOf(0), gateway.uploads.map { it.first })
            gateway.uploadGate.complete(Unit); advanceUntilIdle()
            assertTrue(model.state.value.finished)
            assertEquals(listOf("prepare:0", "prepare:1", "prepare:2"), gateway.events.filter { it.startsWith("prepare:") })
            assertEquals(listOf(0, 1, 2), gateway.uploads.map { it.first })
            gateway.originals.forEachIndexed { index, bytes -> assertArrayEquals(bytes, gateway.uploads[index].second) }
            assertEquals(1, gateway.commits); assertEquals(1, gateway.closes)
            gateway.assertReleased()
        } finally { model.close(); advanceUntilIdle() }
    }

    // Regressions caught: submitting before preparation, losing a connected resource on cancel.
    @Test fun cancellationClosesReadyConnectionAndCancelsPendingPreparation() = runTest(dispatcher) {
        val gateway = Gateway().apply { connectGate.complete(Unit) }
        val model = ShareViewModel(gateway)
        model.start(listOf("0")); runCurrent()
        assertTrue(gateway.events.contains("prepare:0"))
        assertEquals(0, gateway.submissions)
        model.close(); advanceUntilIdle()
        assertEquals(1, gateway.closes)
        assertTrue(gateway.events.contains("prepare-cancelled:0"))
        assertEquals(0, gateway.commits); assertNull(gateway.stored)
        gateway.assertReleased()
    }

    @Test fun cancellationStopsPendingConnectionAfterFirstImageIsReady() = runTest(dispatcher) {
        val gateway = Gateway().apply { prepareGate.complete(Unit) }
        val model = ShareViewModel(gateway)
        try {
            model.start(listOf("0")); runCurrent()
            assertTrue(gateway.events.contains("prepared:0"))
            model.close(); advanceUntilIdle()
            assertTrue(gateway.events.contains("connect-cancelled"))
            assertEquals(0, gateway.submissions); assertEquals(0, gateway.commits)
            gateway.assertReleased()
        } finally { model.close(); advanceUntilIdle() }
    }

    @Test fun connectionFailureCancelsPendingFirstPreparation() = runTest(dispatcher) {
        val gateway = Gateway().apply { connectFailure = DropFailure("Connection failed") }
        val model = ShareViewModel(gateway)
        try {
            model.start(listOf("0")); runCurrent()
            assertTrue(gateway.events.contains("prepare:0"))
            gateway.connectGate.complete(Unit); advanceUntilIdle()
            assertTrue(gateway.events.contains("prepare-cancelled:0"))
            assertEquals(0, gateway.submissions); assertEquals(0, gateway.commits)
            assertFalse(model.state.value.working); assertFalse(model.state.value.committed)
            gateway.assertReleased()
        } finally { model.close(); advanceUntilIdle() }
    }

    @Test fun firstPreparationFailureClosesReadyConnectionWithoutSubmitting() = runTest(dispatcher) {
        val gateway = Gateway().apply { connectGate.complete(Unit); prepareFailure = DropFailure("Image failed") }
        val model = ShareViewModel(gateway)
        model.start(listOf("0")); runCurrent()
        assertTrue(gateway.events.contains("connected"))
        gateway.prepareGate.complete(Unit); advanceUntilIdle()
        assertEquals(1, gateway.closes)
        assertEquals(0, gateway.submissions); assertEquals(0, gateway.commits)
        assertFalse(model.state.value.working); assertFalse(model.state.value.committed)
        assertNull(gateway.stored)
        gateway.assertReleased()
    }

    @Test fun firstPreparationFailureCancelsPendingConnection() = runTest(dispatcher) {
        val gateway = Gateway().apply { prepareFailure = DropFailure("Image failed") }
        val model = ShareViewModel(gateway)
        try {
            model.start(listOf("0")); runCurrent()
            assertTrue(gateway.events.contains("prepare:0"))
            gateway.prepareGate.complete(Unit); advanceUntilIdle()
            assertTrue(gateway.events.contains("connect-cancelled"))
            assertEquals(0, gateway.submissions); assertEquals(0, gateway.commits)
            assertFalse(model.state.value.working)
            gateway.assertReleased()
        } finally { model.close(); advanceUntilIdle() }
    }

    @Test fun connectionFailureAfterFirstPreparationNeverSubmitsOrPreparesMoreImages() = runTest(dispatcher) {
        val gateway = Gateway().apply { prepareGate.complete(Unit); connectFailure = DropFailure("Connection failed") }
        val model = ShareViewModel(gateway)
        try {
            model.start(listOf("0", "1")); runCurrent()
            assertTrue(gateway.events.contains("prepared:0"))
            gateway.connectGate.complete(Unit); advanceUntilIdle()
            assertEquals(listOf("prepare:0"), gateway.events.filter { it.startsWith("prepare:") })
            assertEquals(0, gateway.submissions); assertEquals(0, gateway.commits)
            assertFalse(model.state.value.working); assertNull(gateway.stored)
            gateway.assertReleased()
        } finally { model.close(); advanceUntilIdle() }
    }
}
