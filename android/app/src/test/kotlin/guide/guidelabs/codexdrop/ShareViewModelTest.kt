package guide.guidelabs.codexdrop

import guide.guidelabs.codexdrop.core.*
import guide.guidelabs.codexdrop.platform.PendingReceipt
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.*
import org.junit.Assert.*
import java.util.UUID

@OptIn(ExperimentalCoroutinesApi::class)
class ShareViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    @Before fun setUp() { Dispatchers.setMain(dispatcher) }
    @After fun tearDown() { Dispatchers.resetMain() }
    private class FakeGateway : DropGateway {
        override val slot = TransferSlot()
        var submissions = 0
        var commits = 0
        var lookups = 0
        var commitGate: CompletableDeferred<Unit>? = null
        var persisted = false
        var terminal = "verified"
        var stored: PendingReceipt? = null
        override suspend fun pairing() = Pairing("CodexShot-12345678-1234-1234-1234-123456789abc","a".repeat(64),"b".repeat(43))
        override suspend fun remember(receipt: PendingReceipt) { persisted = true;stored = receipt }
        override suspend fun receipt(id: String) = stored?.takeIf { it.id == id }
        override suspend fun prepare(source: String) = java.nio.ByteBuffer.allocate(33).put(byteArrayOf(-119,80,78,71,13,10,26,10)).putInt(13).put("IHDR".toByteArray()).putInt(1).putInt(1).put(byteArrayOf(8,6,0,0,0)).putInt(0).array()
        override suspend fun connect(pairing: Pairing): DropConnection {
            var id = stored?.id.orEmpty()
            val transport = Transport { request ->
                if (request.path == "v1/batches") { submissions++;id = request.requestId!! }
                val committing = request.path.endsWith("/commit")
                if (committing) { assertTrue(persisted);commits++;commitGate?.await() }
                val lookup = request.path.startsWith("v1/jobs/")
                if (lookup) lookups++
                val state = if (committing || lookup) terminal else "uploading"
                val result = if (state == "verified") """{"verifiedCount":1,"totalCount":1,"items":[{"index":0,"status":"verified"}]}""" else "null"
                val job = """{"id":"$id","state":"$state","result":$result}"""
                HttpReply(if (lookup) 200 else 202, (if (lookup) job else """{"received":true,"job":$job}""").toByteArray())
            }
            return object : DropConnection { override val client = BatchClient(transport);override fun close() = Unit }
        }
    }
    @Test fun repeatedStartDoesNotDeliverTwice() = runTest(dispatcher) {
        val gateway = FakeGateway();val model = ShareViewModel(gateway)
        model.start(listOf("content://fixture/1"));model.start(listOf("content://fixture/1"))
        advanceUntilIdle()
        assertEquals(1,gateway.submissions);assertEquals(1,gateway.commits)
        assertTrue(model.state.value.finished)
    }
    @Test fun processRestorationNeverReplaysTheOriginalShare() = runTest(dispatcher) {
        val gateway = FakeGateway()
        val model = ShareViewModel(gateway,UUID.randomUUID().toString())
        model.start(listOf("content://fixture/1"));advanceUntilIdle()
        assertEquals(0,gateway.submissions);assertEquals(0,gateway.commits)
        assertFalse(model.state.value.finished)
    }
    @Test fun uncertainShareDoesNotCloseOrBlockAFreshShare() = runTest(dispatcher) {
        val gateway = FakeGateway().apply { terminal = "uncertain" }
        val first = ShareViewModel(gateway);first.start(listOf("content://fixture/1"));advanceUntilIdle()
        assertFalse(first.state.value.finished)
        gateway.terminal = "verified"
        val second = ShareViewModel(gateway);second.start(listOf("content://fixture/2"));advanceUntilIdle()
        assertTrue(second.state.value.finished);assertEquals(2,gateway.commits)
    }
    @Test fun cancellingBeforeWorkRunsNeverCommits() = runTest(dispatcher) {
        val gateway = FakeGateway();val model = ShareViewModel(gateway)
        model.start(listOf("content://fixture/1"));model.close();advanceUntilIdle()
        assertEquals(0,gateway.commits);assertTrue(model.state.value.finished)
        assertTrue(gateway.slot.acquire());gateway.slot.release()
    }
    @Test fun closingAfterCommitNeverRetriesAndReleasesTransferSlot() = runTest(dispatcher) {
        val gateway = FakeGateway().apply { commitGate = CompletableDeferred() }
        val model = ShareViewModel(gateway);model.start(listOf("content://fixture/1"));runCurrent()
        assertTrue(model.state.value.committed);assertEquals(1,gateway.commits)
        model.close();advanceUntilIdle()
        assertEquals(1,gateway.commits);assertTrue(gateway.slot.acquire());gateway.slot.release()
    }
    @Test fun recoveryLooksUpOnlyThePersistedReceipt() = runTest(dispatcher) {
        val gateway = FakeGateway()
        val id = UUID.randomUUID().toString()
        gateway.stored = PendingReceipt(id,1,gateway.pairing().service,1L)
        val model = ShareViewModel(gateway,id);model.checkReceipt();advanceUntilIdle()
        assertEquals(0,gateway.submissions);assertEquals(0,gateway.commits);assertEquals(1,gateway.lookups)
        assertTrue(model.state.value.finished)
    }
    @Test fun concurrentSharesAreRefusedInsteadOfQueued() = runTest(dispatcher) {
        val gateway = FakeGateway().apply { commitGate = CompletableDeferred() }
        val first = ShareViewModel(gateway);first.start(listOf("content://fixture/1"));runCurrent()
        val second = ShareViewModel(gateway);second.start(listOf("content://fixture/2"));runCurrent()
        assertFalse(second.state.value.working);assertEquals(1,gateway.submissions)
        first.close();advanceUntilIdle()
        assertEquals(1,gateway.commits)
    }
}
