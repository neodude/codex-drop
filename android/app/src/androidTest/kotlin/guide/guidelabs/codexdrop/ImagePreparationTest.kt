package guide.guidelabs.codexdrop

import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import guide.guidelabs.codexdrop.core.DropFailure
import guide.guidelabs.codexdrop.core.MAX_IMAGE_BYTES
import guide.guidelabs.codexdrop.platform.ImagePreparer
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Synthetic originals only; runner targets the task-owned disposable emulator. */
@RunWith(AndroidJUnit4::class)
class ImagePreparationTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var folder: File
    private lateinit var preparer: ImagePreparer
    @Before fun setup() {
        Assume.assumeTrue("Fixtures run only on a dedicated Codex Drop emulator", Build.PRODUCT.contains("sdk"))
        folder = File(context.cacheDir, "test-original-image-${UUID.randomUUID()}")
        preparer = ImagePreparer(context.contentResolver, folder)
    }
    @After fun cleanup() { if (::folder.isInitialized) folder.deleteRecursively() }
    private fun uri(name: String) = Uri.parse("content://guide.guidelabs.codexdrop.test.images/$name")
    private fun assertNoTemporaryImages() { assertTrue(folder.listFiles().orEmpty().isEmpty()) }
    private fun digest(name: String): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        context.contentResolver.openInputStream(uri(name))!!.use { stream ->
            val buffer = ByteArray(16 * 1024)
            while (true) { val n = stream.read(buffer); if (n == -1) break; digest.update(buffer, 0, n) }
        }
        return digest.digest()
    }
    private suspend fun unchanged(name: String): ByteArray {
        val bytes = preparer.prepare(uri(name))
        assertArrayEquals("Original $name", digest(name), MessageDigest.getInstance("SHA-256").digest(bytes))
        assertNoTemporaryImages()
        return bytes
    }
    @Test fun originalMoviesIncludingGenericAndUnknownProviderTypesKeepEveryByte(): Unit = runBlocking {
        for (name in listOf("original.mp4", "original.mov", "generic-original.mp4", "unknown-original.mov")) unchanged(name)
    }
    @Test fun videoLimitsAndUnsupportedProviderTypesLeaveNoSpool(): Unit = runBlocking {
        for (name in listOf("over-limit.mp4", "unsupported.pdf", "unsupported.webm")) {
            assertThrows(DropFailure::class.java) { runBlocking { preparer.prepare(uri(name)) } }
            assertNoTemporaryImages()
        }
    }
    @Test fun movieCancellationUnlinksSpoolWhileProviderIsBlocked(): Unit = runBlocking {
        val job = launch { preparer.prepare(uri("blocked.mp4")) }
        withTimeout(2_000) { while (!folder.isDirectory) delay(10) }
        delay(100)
        assertTrue(job.isActive)
        assertNoTemporaryImages()
        job.cancelAndJoin()
        assertNoTemporaryImages()
    }
    @Test fun ordinaryCameraPngAndJpegAreUnchanged(): Unit = runBlocking {
        unchanged("camera.png")
        val jpeg = unchanged("camera.jpg")
        val metadata = ExifInterface(ByteArrayInputStream(jpeg))
        assertEquals(3024, metadata.getAttributeInt(ExifInterface.TAG_IMAGE_WIDTH, 0))
        assertEquals(4032, metadata.getAttributeInt(ExifInterface.TAG_IMAGE_LENGTH, 0))
    }
    @Test fun fiftyMiBOriginalsAreAcceptedAndOverLimitStreamsAreRejected(): Unit = runBlocking {
        for (name in listOf("padded-25.png", "padded-50.png")) {
            val bytes = unchanged(name)
            assertEquals(if (name == "padded-25.png") 25 * 1024 * 1024 else MAX_IMAGE_BYTES, bytes.size)
        }
        for (name in listOf("padded-over.png", "too-large")) {
            val failure = assertThrows(DropFailure::class.java) { runBlocking { preparer.prepare(uri(name)) } }
            assertTrue(failure.message!!.contains("50 MiB"))
            assertNoTemporaryImages()
        }
    }
    @Test fun exifOrientationIccProfileAndCommentsSurviveByteForByte(): Unit = runBlocking {
        for (orientation in 1..8) {
            val jpeg = unchanged("oriented-$orientation.jpg")
            val metadata = ExifInterface(ByteArrayInputStream(jpeg))
            assertEquals(orientation, metadata.getAttributeInt(ExifInterface.TAG_ORIENTATION, 0))
            assertEquals("Synthetic original metadata", metadata.getAttribute(ExifInterface.TAG_ARTIST))
            assertEquals("Preserve this original file exactly", metadata.getAttribute(ExifInterface.TAG_USER_COMMENT))
            assertTrue(jpeg.toString(Charsets.ISO_8859_1).contains("ICC_PROFILE"))
            assertEquals(4000, metadata.getAttributeInt(ExifInterface.TAG_IMAGE_WIDTH, 0))
            assertEquals(3500, metadata.getAttributeInt(ExifInterface.TAG_IMAGE_LENGTH, 0))
        }
    }
    @Test fun gifWebpHeicAndLargerPhotosPassThroughWithoutDecoding(): Unit = runBlocking {
        for (name in listOf("original.gif", "original.webp", "original.heic", "large.jpg", "too-many-pixels.png", "not-image")) unchanged(name)
    }
    @Test fun cancellationLeavesNoImageFileEvenWhileProviderIsBlocked(): Unit = runBlocking {
        val job = launch { preparer.prepare(uri("blocked.png")) }
        withTimeout(2_000) { while (!folder.isDirectory) delay(10) }
        delay(100)
        assertTrue(job.isActive)
        assertNoTemporaryImages() // The open private spool has already been unlinked.
        job.cancelAndJoin()
        assertNoTemporaryImages()
    }
    @Test fun providerFailureLeavesNoTemporaryImages(): Unit = runBlocking {
        for (name in listOf("missing", "denied")) {
            assertThrows(DropFailure::class.java) { runBlocking { preparer.prepare(uri(name)) } }
            assertNoTemporaryImages()
        }
    }
}
