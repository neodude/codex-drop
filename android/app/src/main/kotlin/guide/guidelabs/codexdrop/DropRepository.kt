package guide.guidelabs.codexdrop

import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import guide.guidelabs.codexdrop.core.*
import guide.guidelabs.codexdrop.platform.*
import kotlinx.coroutines.CancellationException
import java.io.Closeable
import java.io.File
import java.net.Inet4Address
import java.util.concurrent.atomic.AtomicBoolean

const val LAN_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
fun Context.hasLanPermission() = Build.VERSION.SDK_INT < 37 || checkSelfPermission(LAN_PERMISSION) == PackageManager.PERMISSION_GRANTED

class TransferSlot {
    private val occupied = AtomicBoolean(false)
    fun acquire() = occupied.compareAndSet(false, true)
    fun release() { occupied.set(false) }
}
interface DropConnection : Closeable { val client: BatchClient }
interface DropGateway {
    val slot: TransferSlot
    suspend fun pairing(): Pairing?
    suspend fun remember(receipt: PendingReceipt)
    suspend fun receipt(id: String): PendingReceipt?
    suspend fun prepare(source: String): ByteArray
    suspend fun connect(pairing: Pairing): DropConnection
}
class DropApplication : Application() {
    // Internal replacement is used only by in-process instrumentation, never by intents.
    internal var repositoryOverride: DropRepository? = null
    private val defaultRepository by lazy { DropRepository(this) }
    val repository get() = repositoryOverride ?: defaultRepository
}
class DropRepository(private val context: Context, private val discovery: ReceiverDiscovery = NsdReceiverDiscovery(context)) : DropGateway {
    override val slot = TransferSlot()
    private val pairingStore = PairingStore(context)
    private val receipts = ReceiptStore(File(context.noBackupFilesDir, "receipts"))
    private val images = ImagePreparer(context.contentResolver, File(context.cacheDir, "image-preparation"))
    override suspend fun pairing() = pairingStore.load()
    override suspend fun remember(receipt: PendingReceipt) = receipts.save(receipt)
    override suspend fun receipt(id: String) = receipts.find(id)
    override suspend fun prepare(source: String) = images.prepare(Uri.parse(source))
    suspend fun latestReceipt() = receipts.latest()
    suspend fun forget() = pairingStore.forget()
    suspend fun pair(code: String) {
        val pairing = Pairing.parse(code)
        connect(pairing).use { pairingStore.save(code) }
    }
    override suspend fun connect(pairing: Pairing): DropConnection {
        if (!context.hasLanPermission()) throw DropFailure("Allow Local Network access in Android settings so Codex Drop can find your Mac.")
        val endpoint = discovery.resolve(pairing.service)
        // Probe only a read-only endpoint before selecting a route. Never retry a submission.
        for (address in endpoint.addresses.sortedBy { if (it is Inet4Address) 0 else 1 }) {
            val transport = PinnedHttpsTransport(pairing, Endpoint(listOf(address), endpoint.port))
            val client = BatchClient(transport)
            try {
                client.checkConnection()
                return object : DropConnection { override val client = client; override fun close() = transport.close() }
            } catch (cancelled: CancellationException) { transport.close(); throw cancelled }
            catch (error: Exception) {
                android.util.Log.w("CodexDrop", "Connection probe failed: " + error.javaClass.name + " / " + (error.cause?.javaClass?.name ?: "none"))
                transport.close()
            }
        }
        throw DropFailure("Couldn’t securely connect to your paired Mac. Check the receiver, Wi-Fi and pairing.")
    }
}
