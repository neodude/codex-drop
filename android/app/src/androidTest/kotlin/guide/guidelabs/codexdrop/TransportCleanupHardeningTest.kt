package guide.guidelabs.codexdrop

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class TransportCleanupHardeningTest : HardeningFixture() {
    @Test fun closingPinnedTlsOnMainDoesNotPerformNetworkIo(): Unit = runBlocking {
        val connection = repository.connect(repository.pairing()!!)
        val error = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync { try { connection.close() } catch (caught: Throwable) { error.set(caught) } }
        assertNull("TLS cleanup threw on Main: ${error.get()?.javaClass?.simpleName}",error.get())
        connection.close() // idempotent cleanup
    }
}
