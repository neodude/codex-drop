package guide.guidelabs.codexdrop.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive

const val MAX_IMAGE_BYTES = 50 * 1024 * 1024
const val MAX_BATCH_BYTES = 100 * 1024 * 1024

data class HttpRequest(val path: String, val body: ByteArray? = null, val contentType: String = "application/json", val requestId: String? = null)
data class HttpReply(val statusCode: Int, val body: ByteArray)
fun interface Transport { suspend fun execute(request: HttpRequest): HttpReply }
sealed interface TransferProgress {
    data class Preparing(val index: Int, val count: Int) : TransferProgress
    data class Uploading(val index: Int, val count: Int) : TransferProgress
    data object Committing : TransferProgress
    data object Confirming : TransferProgress
}

fun validateImageBytes(bytes: ByteArray) {
    if (bytes.isEmpty()) throw DropFailure("The shared file is empty. Share it again from Photos.")
    if (bytes.size > MAX_IMAGE_BYTES) throw DropFailure("Each file must be at most 50 MiB.")
}

class BatchClient(private val transport: Transport, private val pollTimeoutMillis: Long = 120_000, private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000 }) {
    suspend fun checkConnection() {
        requireStatus(transport.execute(HttpRequest("v1/jobs/00000000-0000-0000-0000-000000000000")), setOf(404))
    }
    suspend fun lookup(id: String): DeliveryJob {
        if (!validId(id)) throw DropFailure("This receipt has an invalid request ID.")
        val response = transport.execute(HttpRequest("v1/jobs/$id"))
        requireStatus(response, setOf(200))
        return try {
            DeliveryJob.parse(StrictJson.objectValue(response.body)).also { require(it.id == id) }
        } catch (_: Exception) { throw DropFailure("The Mac returned an invalid receipt. Check attachments before sharing again.", true) }
    }
    suspend fun attach(count: Int, id: String, prepare: suspend (Int) -> ByteArray, beforeCommit: suspend () -> Unit = {}, progress: (TransferProgress) -> Unit = {}): DeliveryJob {
        if (count !in 1..10 || !validId(id)) throw DropFailure("Share 1–10 files in one new request.")
        var commitStarted = false
        try {
            currentCoroutineContext().ensureActive()
            val created = receipt(transport.execute(HttpRequest("v1/batches", "{\"count\":$count}".toByteArray(), requestId = id)), id)
            if (created.state != "uploading") throw DropFailure("This request already exists. Check your Mac before sharing again.", true)
            var totalBytes = 0L
            for (index in 0 until count) {
                currentCoroutineContext().ensureActive()
                progress(TransferProgress.Preparing(index, count))
                // Each image is scoped to one upload; never retain the whole batch.
                val image = prepare(index)
                currentCoroutineContext().ensureActive()
                validateImageBytes(image)
                totalBytes += image.size
                if (totalBytes > MAX_BATCH_BYTES) throw DropFailure("The batch must be at most 100 MiB.")
                progress(TransferProgress.Uploading(index, count))
                val staged = receipt(transport.execute(HttpRequest("v1/batches/$id/images/$index", image, "application/octet-stream")), id)
                if (staged.state != "uploading") throw DropFailure("The Mac returned an unexpected staging receipt. Check before sharing again.", true)
            }
            currentCoroutineContext().ensureActive()
            beforeCommit() // Persist recovery identity before a request can cause attachment.
            currentCoroutineContext().ensureActive()
            commitStarted = true
            progress(TransferProgress.Committing)
            var job = receipt(transport.execute(HttpRequest("v1/batches/$id/commit", "{}".toByteArray())), id)
            progress(TransferProgress.Confirming)
            val deadline = nowMillis() + pollTimeoutMillis
            while (job.state in setOf("queued", "running")) {
                val remaining = deadline - nowMillis()
                if (remaining <= 0) throw DropFailure("The Mac received the files, but attachment is not confirmed. Check Codex before sharing again.", true)
                delay(minOf(180, remaining))
                if (nowMillis() >= deadline) throw DropFailure("Attachment confirmation timed out. Check Codex before sharing again.", true)
                job = lookup(id)
            }
            if (job.state == "uploading") throw DropFailure("The Mac did not confirm the commit. Check Codex before sharing again.", true)
            return job
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) {
            if (commitStarted) throw DropFailure("Attachment isn’t confirmed. Some files may already be attached. Check Codex before sharing again. No automatic retry.", true)
            if (error is DropFailure) throw error
            throw DropFailure("The transfer was interrupted before attachment. Check the receiver, Wi-Fi and file limits.")
        }
    }
    private fun receipt(response: HttpReply, id: String): DeliveryJob {
        requireStatus(response, setOf(200, 202))
        return try {
            val root = StrictJson.objectValue(response.body); require(root["received"] == true)
            @Suppress("UNCHECKED_CAST") val job = root["job"] as? Map<String, Any?> ?: throw IllegalArgumentException()
            DeliveryJob.parse(job).also { require(it.id == id) }
        } catch (_: Exception) { throw DropFailure("The Mac returned an invalid receipt. No automatic retry.") }
    }
    private fun requireStatus(response: HttpReply, accepted: Set<Int>) {
        if (response.statusCode == 401) throw DropFailure("Pairing was rejected. Scan the Mac’s QR code again.")
        if (response.statusCode !in accepted) {
            val error = runCatching { StrictJson.objectValue(response.body) }.getOrNull()
            if (error?.get("error") == "unsupported_image_format") {
                val message = (error["message"] as? String)?.takeIf { it.length in 1..512 && it.isNotBlank() && it.none(Char::isISOControl) }
                    ?: "Codex accepts JPEG, PNG, GIF, WebP, MP4 and MOV files. Share one of those formats instead."
                throw DropFailure(message)
            }
            throw DropFailure("The Mac refused the request. Check the receiver before sharing again. No automatic retry.")
        }
    }
}
