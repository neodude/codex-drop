package guide.guidelabs.codexdrop

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import guide.guidelabs.codexdrop.core.*
import guide.guidelabs.codexdrop.platform.*
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

@RunWith(AndroidJUnit4::class)
class PermissionHardeningTest : HardeningFixture() {
    @Test fun deniedLanAccessStopsBeforeDiscoveryOrUpload(): Unit = runBlocking {
        Assume.assumeTrue(Build.VERSION.SDK_INT >= 37)
        assertFalse(context.hasLanPermission())
        var discoveries = 0
        val denied = DropRepository(context,ReceiverDiscovery { discoveries++;endpoint() })
        assertThrows(DropFailure::class.java) { runBlocking { denied.connect(repository.pairing()!!) } }
        assertEquals(0,discoveries)
        val (_,model) = launch()
        awaitReview(model)
        assertTrue(model.state.value.detail.contains("Local Network"));assertFalse(model.state.value.committed)
        assertNull(repository.latestReceipt()?.takeIf { it.id == model.requestId })
        close(model)
    }
}
@RunWith(AndroidJUnit4::class)
class DiscoveryHardeningTest : HardeningFixture() {
    @Test fun unavailableReceiverFailsBeforeAnyUpload() {
        val offline = DropRepository(context,ReceiverDiscovery { Endpoint(endpoint().addresses,9) })
        (context.applicationContext as DropApplication).repositoryOverride = offline
        val (_,model) = launch()
        awaitReview(model)
        assertFalse(model.state.value.committed);assertFalse(model.state.value.canCheck)
        close(model)
    }
    @Test fun absentNativeServiceTimesOutAndCancellationCanBeRepeated(): Unit = runBlocking {
        val discovery = NsdReceiverDiscovery(context)
        val missing = "CodexShot-${UUID.randomUUID()}"
        val start = SystemClock.elapsedRealtime()
        assertThrows(DropFailure::class.java) { runBlocking { discovery.resolve(missing) } }
        assertTrue("Discovery must be bounded",SystemClock.elapsedRealtime() - start < 10_000)
        repeat(3) {
            val job = launch { discovery.resolve(missing) }
            delay(150);job.cancelAndJoin()
            assertTrue(job.isCancelled)
        }
    }
    @Test fun nativeRegistrationAndExactInstanceResolutionWork(): Unit = runBlocking {
        val nsd = context.getSystemService(NsdManager::class.java)
        val registered = CompletableDeferred<NsdServiceInfo>()
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) { registered.complete(info) }
            override fun onRegistrationFailed(info: NsdServiceInfo,error: Int) { registered.completeExceptionally(AssertionError("Native NSD registration failed: $error")) }
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo,error: Int) = Unit
        }
        try {
            nsd.registerService(NsdServiceInfo().apply { serviceName = "CodexShot-${UUID.randomUUID()}";serviceType = "_codexshot._tcp.";port = 43210 },NsdManager.PROTOCOL_DNS_SD,listener)
            val name = withTimeout(10_000) { registered.await().serviceName }
            val found = NsdReceiverDiscovery(context).resolve(name)
            assertEquals(43210,found.port);assertTrue(found.addresses.isNotEmpty())
        } finally { runCatching { nsd.unregisterService(listener) } }
    }
}
