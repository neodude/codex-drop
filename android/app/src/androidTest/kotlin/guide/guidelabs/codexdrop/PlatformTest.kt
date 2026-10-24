package guide.guidelabs.codexdrop

import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import guide.guidelabs.codexdrop.core.Pairing
import guide.guidelabs.codexdrop.core.DropFailure
import guide.guidelabs.codexdrop.platform.*
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.io.File
import java.util.Base64
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class PlatformTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    @Before fun emulatorOnly() { Assume.assumeTrue("Fixtures run only on the dedicated emulator", Build.PRODUCT.contains("sdk")) }
    private fun code(): String {
        val json = """{"v":1,"service":"CodexShot-12345678-1234-1234-1234-123456789abc","pin":"${"a".repeat(64)}","token":"${"b".repeat(43)}"}"""
        return "codexshot://pair?data=" + Base64.getUrlEncoder().withoutPadding().encodeToString(json.toByteArray())
    }
    @Test fun pairingIsEncryptedAndCanBeRemovedWithoutTouchingMacIdentity(): Unit = runBlocking {
        val name = "test-${UUID.randomUUID()}"
        val store = PairingStore(context, name)
        try {
            val qr = code(); store.save(qr)
            assertEquals(Pairing.parse(qr), store.load())
            val encrypted = File(context.noBackupFilesDir, "$name.enc").readBytes()
            assertFalse(encrypted.decodeToString().contains(qr))
            assertFalse(encrypted.decodeToString().contains("b".repeat(43)))
            store.forget(); assertNull(store.load())
        } finally { store.forget() }
    }
    @Test fun receiptsAreDurablePerRequestAndDoNotBlockFreshRequests(): Unit = runBlocking {
        val folder = File(context.noBackupFilesDir, "test-receipts-${UUID.randomUUID()}")
        val store = ReceiptStore(folder)
        try {
            val first = PendingReceipt(UUID.randomUUID().toString(), 3, Pairing.parse(code()).service, System.currentTimeMillis())
            val second = first.copy(id = UUID.randomUUID().toString())
            store.save(first);store.save(second)
            assertEquals(first, store.find(first.id));assertEquals(second, store.latest())
            assertThrows(DropFailure::class.java) { runBlocking { store.find("../pairing") } }
        } finally { folder.deleteRecursively() }
    }
    @Test fun imageReadingIsBoundedAndKeepsOriginalBytes(): Unit = runBlocking {
        val preparer = ImagePreparer(context.contentResolver, File(context.cacheDir, "test-image-preparation"))
        val tiny = Uri.parse("content://guide.guidelabs.codexdrop.test.images/tiny.png")
        val original = context.contentResolver.openInputStream(tiny)!!.use { it.readBytes() }
        assertArrayEquals(original, preparer.prepare(tiny))
        val jpegUri = Uri.parse("content://guide.guidelabs.codexdrop.test.images/tiny.jpg")
        val jpegOriginal = context.contentResolver.openInputStream(jpegUri)!!.use { it.readBytes() }
        assertArrayEquals(jpegOriginal, preparer.prepare(jpegUri))
        for (path in listOf("not-image", "too-many-pixels.png")) {
            val source = Uri.parse("content://guide.guidelabs.codexdrop.test.images/$path")
            val bytes = context.contentResolver.openInputStream(source)!!.use { it.readBytes() }
            assertArrayEquals(bytes, preparer.prepare(source)) // Receiver validates format and dimensions.
        }
        for (path in listOf("too-large", "missing", "denied")) {
            assertThrows(DropFailure::class.java) { runBlocking { preparer.prepare(Uri.parse("content://guide.guidelabs.codexdrop.test.images/$path")) } }
        }
        assertThrows(DropFailure::class.java) { runBlocking { preparer.prepare(Uri.parse("file:///etc/passwd")) } }
    }
}
