package guide.guidelabs.codexdrop.platform

import android.content.ContentResolver
import android.net.Uri
import android.os.CancellationSignal
import guide.guidelabs.codexdrop.core.*
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Reads the provider's original stream without decoding or modifying the file. */
class ImagePreparer(private val resolver: ContentResolver, private val cacheDirectory: File) {
    companion object {
        // Bound even a broken provider that ignores cancellation; never accumulate queued reads.
        private val workers = ThreadPoolExecutor(0,2,30,TimeUnit.SECONDS,SynchronousQueue(), { runnable -> Thread(runnable,"CodexDrop-media").apply { isDaemon = true } })
    }
    suspend fun prepare(uri: Uri): ByteArray {
        if (uri.scheme != "content") throw DropFailure("Share a photo or video from another app.")
        try {
            return withTimeout(120_000) {
                suspendCancellableCoroutine { continuation ->
                    val signal = CancellationSignal()
                    val streamRef = AtomicReference<InputStream?>()
                    try {
                        val future = workers.submit {
                            var temporary: File? = null
                            var result: ByteArray? = null
                            var failure: Exception? = null
                            fun checkActive() { if (!continuation.isActive || Thread.currentThread().isInterrupted) throw InterruptedException() }
                            try {
                                checkActive()
                                validateProviderMime(resolver.getType(uri))
                                checkActive()
                                cacheDirectory.mkdirs()
                                val original = File.createTempFile("codex-drop-original-", ".tmp", cacheDirectory)
                                temporary = original
                                val bytes = RandomAccessFile(original, "rw").use { cache ->
                                    // Unlink immediately: even process death cannot leave a cached file behind.
                                    if (!original.delete()) throw DropFailure("Couldn’t create a private file buffer. Try sharing again.")
                                    resolver.openAssetFileDescriptor(uri,"r",signal)?.use { asset ->
                                        asset.createInputStream().use { stream ->
                                            streamRef.set(stream)
                                            val buffer = ByteArray(16 * 1024)
                                            var total = 0L
                                            while (true) {
                                                checkActive()
                                                val count = stream.read(buffer)
                                                if (count == -1) break
                                                total += count
                                                if (total > MAX_IMAGE_BYTES) throw DropFailure("Each file must be at most 50 MiB.")
                                                cache.write(buffer,0,count)
                                            }
                                        }
                                    } ?: throw DropFailure("Couldn’t open the shared file. Share it again from Photos.")
                                    streamRef.set(null)
                                    checkActive()
                                    // Allocate once after bounding the stream; never decode or copy an expanding buffer.
                                    val image = ByteArray(cache.length().toInt())
                                    cache.seek(0)
                                    var offset = 0
                                    while (offset < image.size) {
                                        checkActive()
                                        val count = minOf(16 * 1024, image.size - offset)
                                        cache.readFully(image, offset, count)
                                        offset += count
                                    }
                                    image
                                }
                                validateImageBytes(bytes)
                                checkActive()
                                result = bytes
                            } catch (_: OutOfMemoryError) {
                                failure = DropFailure("There isn’t enough memory to read this file. Try a smaller file.")
                            } catch (error: Exception) {
                                failure = if (error is DropFailure) error else DropFailure("Couldn’t read this file. Its sharing permission may have expired.")
                            } finally {
                                streamRef.set(null)
                                temporary?.delete()
                            }
                            if (continuation.isActive) {
                                failure?.let { continuation.resumeWithException(it) }
                                    ?: result?.let { continuation.resume(it) }
                            }
                        }
                        continuation.invokeOnCancellation { runCatching { signal.cancel() };runCatching { streamRef.getAndSet(null)?.close() };future.cancel(true) }
                    } catch (_: Exception) { continuation.resumeWithException(DropFailure("Another file is still being read. Try a fresh share shortly.")) }
                }
            }
        } catch (_: TimeoutCancellationException) { throw DropFailure("Reading this file timed out. This batch was not attached.") }
    }
}
