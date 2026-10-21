package guide.guidelabs.codexdrop

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import guide.guidelabs.codexdrop.core.*
import guide.guidelabs.codexdrop.platform.PendingReceipt
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

data class ShareUiState(
    val title: String = "Finding your Mac",
    val detail: String = "Connecting to your paired receiver…",
    val stage: Int = 0,
    val working: Boolean = true,
    val committed: Boolean = false,
    val canCheck: Boolean = false,
    val finished: Boolean = false,
)
class ShareViewModel(private val gateway: DropGateway, restoredId: String? = null) : ViewModel() {
    val requestId = restoredId ?: UUID.randomUUID().toString()
    private var started = restoredId != null
    private var work: Job? = null
    private val mutableState = MutableStateFlow(if (restoredId == null) ShareUiState() else ShareUiState(
        title = "Share interrupted", detail = "Check Codex on your Mac. You can look up this receipt without sending the images again.", working = false, committed = true, canCheck = true))
    val state = mutableState.asStateFlow()
    fun fail(message: String) {
        if (started) return
        started = true
        mutableState.value = ShareUiState("Couldn’t attach", message, working = false)
    }
    fun start(sources: List<String>) {
        if (started) return
        started = true
        if (sources.size !in 1..10) { mutableState.value = ShareUiState("Choose 1–10 images", "Share screenshots or images from another app.", working = false); return }
        work = viewModelScope.launch {
            if (!gateway.slot.acquire()) { mutableState.value = ShareUiState("Another share is in progress", "Let it finish before sharing again. This share has not been queued.", working = false); return@launch }
            try {
                val pairing = gateway.pairing() ?: throw DropFailure("Open Codex Drop and scan the Mac’s pairing QR code first.")
                gateway.connect(pairing).use { connection ->
                    val result = connection.client.attach(sources.size, requestId,
                        prepare = { gateway.prepare(sources[it]) },
                        beforeCommit = { gateway.remember(PendingReceipt(requestId, sources.size, pairing.service, System.currentTimeMillis())) },
                        progress = { progress ->
                            mutableState.value = when (progress) {
                                is TransferProgress.Preparing -> ShareUiState("Preparing image ${progress.index + 1} of ${progress.count}", "Getting your screenshots ready…", 1)
                                is TransferProgress.Uploading -> ShareUiState("Sending image ${progress.index + 1} of ${progress.count}", "Transferring securely to your Mac…", 1)
                                TransferProgress.Committing -> ShareUiState("Attaching in Codex", "Your Mac is adding the images to the active draft…", 2, committed = true)
                                TransferProgress.Confirming -> ShareUiState("Checking attachments", "Waiting for the Mac to verify your draft…", 2, committed = true)
                            }
                        })
                    showResult(result, sources.size)
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                // Structural diagnostics only: never exception messages, image URIs or pairing data.
                android.util.Log.e("CodexDrop", error.javaClass.name + ": " + error.stackTrace.take(8).joinToString { it.className + "." + it.methodName + ":" + it.lineNumber })
                val uncertain = mutableState.value.committed || (error is DropFailure && error.mayBeAttached)
                mutableState.value = ShareUiState(if (uncertain) "Check your Mac" else "Couldn’t attach",
                    if (error is DropFailure) error.message.orEmpty() else "The transfer stopped. Check the Mac and Wi-Fi before sharing again.",
                    working = false, committed = uncertain, canCheck = uncertain)
            } finally { gateway.slot.release() }
        }
    }
    private fun showResult(result: DeliveryJob, count: Int) {
        mutableState.value = if (result.allVerified(count)) ShareUiState("Attached", "$count images added to your draft.", 3, working = false, committed = true, finished = true)
        else ShareUiState("Check your Mac", result.reviewMessage(), 2, working = false, committed = true, canCheck = true)
    }
    fun checkReceipt() {
        if (mutableState.value.working) return
        mutableState.value = mutableState.value.copy(working = true, detail = "Looking up the existing receipt…")
        work = viewModelScope.launch {
            try {
                val receipt = gateway.receipt(requestId) ?: throw DropFailure("No saved receipt exists for this share. Check Codex on your Mac; images will not be resent.", true)
                val pairing = gateway.pairing()?.takeIf { it.service == receipt.service } ?: throw DropFailure("Pair with the original Mac to check this receipt.", true)
                gateway.connect(pairing).use { showResult(it.client.lookup(receipt.id), receipt.count) }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { mutableState.value = mutableState.value.copy(working = false, detail = if (error is DropFailure) error.message.orEmpty() else "Couldn’t check the receipt. Check Codex on your Mac.") }
        }
    }
    fun close() { work?.cancel(); mutableState.value = mutableState.value.copy(finished = true) }
}
