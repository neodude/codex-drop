package guide.guidelabs.codexdrop

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import guide.guidelabs.codexdrop.core.DropFailure
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

data class SetupState(val busy: Boolean = false, val paired: Boolean = false, val message: String = "Scan the QR code in Codex Drop on your Mac to get started.")
class MainViewModel(private val repository: DropRepository) : ViewModel() {
    private val mutableState = MutableStateFlow(SetupState())
    val state = mutableState.asStateFlow()
    init { action { val paired = repository.pairing() != null; mutableState.value = SetupState(paired = paired, message = if (paired) "Paired with your Mac. Share photos or videos to Codex Drop from any app." else SetupState().message) } }
    fun message(text: String) { mutableState.value = mutableState.value.copy(message = text) }
    private fun action(block: suspend () -> Unit) {
        if (mutableState.value.busy) return
        mutableState.value = mutableState.value.copy(busy = true)
        viewModelScope.launch {
            try { block() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { message(if (error is DropFailure) error.message.orEmpty() else "Couldn’t complete the request. Check your Mac and Wi-Fi.") }
            finally { mutableState.value = mutableState.value.copy(busy = false) }
        }
    }
    fun pair(code: String) = action {
        repository.pair(code)
        mutableState.value = SetupState(paired = true, message = "Connected to your Mac. Share photos or videos to Codex Drop from any app.")
    }
    fun check() = action {
        val pairing = repository.pairing() ?: throw DropFailure("Pair with your Mac first.")
        repository.connect(pairing).use { message("Mac connected. Ready to attach to the active Codex draft.") }
    }
    fun forget() = action { repository.forget(); mutableState.value = SetupState() }
    fun receipt() = action {
        val saved = repository.latestReceipt() ?: throw DropFailure("No previous share receipt on this phone.")
        val pairing = repository.pairing()?.takeIf { it.service == saved.service } ?: throw DropFailure("Pair with the original Mac to check this receipt.")
        repository.connect(pairing).use {
            val result = it.client.lookup(saved.id)
            message(if (result.allVerified(saved.count)) "${saved.count} of ${saved.count} files verified attached." else result.reviewMessage())
        }
    }
}
