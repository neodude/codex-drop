package guide.guidelabs.codexdrop.platform

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.CancellationSignal
import guide.guidelabs.codexdrop.core.*
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class ImagePreparer(private val resolver: ContentResolver) {
    companion object {
        // Bound even a broken provider that ignores cancellation; never accumulate queued reads.
        private val workers = ThreadPoolExecutor(0,2,30,TimeUnit.SECONDS,SynchronousQueue(), { runnable -> Thread(runnable,"CodexDrop-image").apply { isDaemon = true } })
    }
    suspend fun prepare(uri: Uri): ByteArray {
        if (uri.scheme != "content") throw DropFailure("Share an image from the screenshot preview or Photos.")
        try {
            return withTimeout(20_000) {
                suspendCancellableCoroutine { continuation ->
                    val signal = CancellationSignal()
                    val streamRef = AtomicReference<InputStream?>()
                    try {
                        val future = workers.submit {
                            try {
                                val input = resolver.openAssetFileDescriptor(uri,"r",signal)?.use { asset ->
                                    asset.createInputStream().use { stream ->
                                        streamRef.set(stream)
                                        val output = ByteArrayOutputStream();val buffer = ByteArray(16 * 1024)
                                        while (continuation.isActive) {
                                            val count = stream.read(buffer)
                                            if (count == -1) break
                                            if (output.size().toLong() + count > MAX_IMAGE_BYTES) throw DropFailure("Each image must be at most 20 MiB.")
                                            output.write(buffer,0,count)
                                        }
                                        if (!continuation.isActive) throw InterruptedException()
                                        output.toByteArray()
                                    }
                                } ?: throw DropFailure("Couldn’t open the shared image. Share it again from Photos.")
                                streamRef.set(null)
                                if (!continuation.isActive) return@submit
                                val png = encode(input)
                                if (continuation.isActive) continuation.resume(png)
                            } catch (error: Exception) {
                                if (continuation.isActive) continuation.resumeWithException(if (error is DropFailure) error else DropFailure("Couldn’t read this image. Its sharing permission may have expired."))
                            }
                        }
                        continuation.invokeOnCancellation { runCatching { signal.cancel() };runCatching { streamRef.getAndSet(null)?.close() };future.cancel(true) }
                    } catch (_: Exception) { continuation.resumeWithException(DropFailure("Another image is still being prepared. Try a fresh share shortly.")) }
                }
            }
        } catch (_: TimeoutCancellationException) { throw DropFailure("Reading this image timed out. This batch was not attached.") }
    }
    private fun encode(input: ByteArray): ByteArray {
        if (input.size >= 8 && input.copyOf(8).contentEquals(byteArrayOf(-119,80,78,71,13,10,26,10))) {
            validatePng(input);return input
        }
        val source = ImageDecoder.createSource(ByteBuffer.wrap(input))
        val bitmap = ImageDecoder.decodeBitmap(source) { decoder,info,_ ->
            val pixels = info.size.width.toLong() * info.size.height
            if (pixels !in 1..MAX_PIXELS) throw DropFailure("This image exceeds 12 million pixels. Crop it before sharing.")
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
        }
        try {
            val output = object : ByteArrayOutputStream() {
                override fun write(bytes: ByteArray, offset: Int, length: Int) {
                    if (size().toLong() + length > MAX_IMAGE_BYTES) throw DropFailure("The prepared PNG exceeds 20 MiB.")
                    super.write(bytes,offset,length)
                }
                override fun write(byte: Int) {
                    if (size() >= MAX_IMAGE_BYTES) throw DropFailure("The prepared PNG exceeds 20 MiB.")
                    super.write(byte)
                }
            }
            if (!bitmap.compress(Bitmap.CompressFormat.PNG,100,output)) throw DropFailure("Couldn’t prepare this image as PNG.")
            return output.toByteArray().also(::validatePng)
        } finally { bitmap.recycle() }
    }
}
