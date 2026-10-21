package guide.guidelabs.codexdrop

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import android.graphics.Color
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import guide.guidelabs.codexdrop.core.DropFailure
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import kotlinx.coroutines.launch

internal inline fun <reified T : ViewModel> ComponentActivity.model(crossinline factory: () -> T): T = ViewModelProvider(this, object : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST") override fun <V : ViewModel> create(clazz: Class<V>): V = factory() as V
})[T::class.java]

class MainActivity : ComponentActivity() {
    private lateinit var model: MainViewModel
    private val permission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) scan() else model.message("Allow Local Network access in Android settings to connect to your Mac.")
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT), navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT))
        model = model { MainViewModel((application as DropApplication).repository) }
        setContent { DropTheme { SetupScreen(model.state, onPair = {
            if (hasLanPermission()) scan() else permission.launch(LAN_PERMISSION)
        }, onCheck = model::check, onForget = model::forget, onReceipt = model::receipt) } }
    }
    private fun scan() {
        val scanner = GmsBarcodeScanning.getClient(this, GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).enableAutoZoom().build())
        scanner.startScan().addOnSuccessListener { result ->
            result.rawValue?.let(model::pair) ?: model.message("That QR code couldn’t be read. Scan the Mac’s pairing QR code.")
        }.addOnFailureListener { model.message("The QR scanner isn’t available yet. Connect this phone to the internet for its first scanner setup, then try again.") }
    }
}
class ShareActivity : ComponentActivity() {
    private lateinit var model: ShareViewModel
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT), navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT))
        model = model { ShareViewModel((application as DropApplication).repository, savedInstanceState?.getString("requestId")) }
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) { override fun handleOnBackPressed() { model.close() } })
        setContent { DropTheme { ShareScreen(model.state, onClose = model::close, onReceipt = model::checkReceipt, onSetup = {
            model.close(); startActivity(Intent(this, MainActivity::class.java))
        }) } }
        lifecycleScope.launch { model.state.collect { if (it.finished) finish() } }
        if (!hasLanPermission()) model.fail("Open Codex Drop and allow Local Network access before sharing.")
        else try { model.start(IncomingShare.read(intent)) }
        catch (error: DropFailure) { model.fail(error.message.orEmpty()) }
    }
    override fun onSaveInstanceState(outState: Bundle) { outState.putString("requestId", model.requestId); super.onSaveInstanceState(outState) }
}
