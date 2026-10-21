package guide.guidelabs.codexdrop.platform

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import guide.guidelabs.codexdrop.core.DropFailure
import guide.guidelabs.codexdrop.core.Endpoint
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

fun interface ReceiverDiscovery { suspend fun resolve(service: String): Endpoint }

class NsdReceiverDiscovery(context: Context) : ReceiverDiscovery {
    private val nsd = context.getSystemService(NsdManager::class.java)
    override suspend fun resolve(service: String): Endpoint {
        try {
            return withTimeout(6500) {
                suspendCancellableCoroutine { continuation ->
                    val completed = AtomicBoolean(false)
                    val resolving = AtomicBoolean(false)
                    lateinit var discovery: NsdManager.DiscoveryListener
                    fun stop() { runCatching { nsd.stopServiceDiscovery(discovery) } }
                    fun fail() {
                        if (completed.compareAndSet(false,true)) {
                            stop();continuation.resumeWithException(DropFailure("Mac not found. Check the receiver, same Wi-Fi and Local Network permission."))
                        }
                    }
                    @Suppress("DEPRECATION") val resolver = object : NsdManager.ResolveListener {
                        override fun onResolveFailed(info: NsdServiceInfo, error: Int) { fail() }
                        override fun onServiceResolved(info: NsdServiceInfo) {
                            val addresses = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
                            if (addresses.isEmpty() || info.port !in 1..65535) { fail();return }
                            if (completed.compareAndSet(false,true)) { stop();continuation.resume(Endpoint(addresses,info.port)) }
                        }
                    }
                    discovery = object : NsdManager.DiscoveryListener {
                        override fun onDiscoveryStarted(type: String) { if (completed.get()) stop() }
                        override fun onDiscoveryStopped(type: String) = Unit
                        override fun onServiceLost(info: NsdServiceInfo) = Unit
                        override fun onStopDiscoveryFailed(type: String, error: Int) = Unit
                        override fun onStartDiscoveryFailed(type: String, error: Int) { fail() }
                        @Suppress("DEPRECATION") override fun onServiceFound(info: NsdServiceInfo) {
                            if (!completed.get() && info.serviceName == service && resolving.compareAndSet(false,true)) {
                                try { nsd.resolveService(info,resolver) } catch (_: Exception) { fail() }
                            }
                        }
                    }
                    continuation.invokeOnCancellation { completed.set(true);stop() }
                    if (!continuation.isActive) return@suspendCancellableCoroutine
                    try { nsd.discoverServices("_codexshot._tcp.",NsdManager.PROTOCOL_DNS_SD,discovery) }
                    catch (_: Exception) { fail() }
                }
            }
        } catch (_: TimeoutCancellationException) {
            throw DropFailure("Mac not found. Check the receiver, same Wi-Fi and Local Network permission.")
        }
    }
}
