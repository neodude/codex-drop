package guide.guidelabs.codexdrop

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import guide.guidelabs.codexdrop.core.*
import guide.guidelabs.codexdrop.platform.ReceiverDiscovery
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.io.File
import java.net.InetAddress

@RunWith(AndroidJUnit4::class)
class FlowTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    @Before fun emulatorOnly() { Assume.assumeTrue(Build.PRODUCT.contains("sdk")) }
    private fun uri(index: Int) = Uri.parse("content://guide.guidelabs.codexdrop.test.images/$index.png")
    private fun share(count: Int) = Intent(context, ShareActivity::class.java).setAction(if (count == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE).setType("image/png").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION).also {
        if (count == 1) it.putExtra(Intent.EXTRA_STREAM, uri(0)) else it.putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList((0 until count).map(::uri)))
        it.clipData = ClipData.newRawUri("fixture",uri(0))
    }
    @Test fun shareIntentUsesStreamsOnceAndRejectsInvalidInputs() {
        assertEquals(3,IncomingShare.read(share(3)).size)
        val clipOnly = share(1).apply { removeExtra(Intent.EXTRA_STREAM) }
        assertEquals(listOf(uri(0).toString()),IncomingShare.read(clipOnly))
        for (invalid in listOf(share(11), share(1).setType("text/plain"), share(1).putExtra(Intent.EXTRA_STREAM,Uri.parse("file:///etc/passwd")), share(1).putExtra(Intent.EXTRA_STREAM,"not a URI"))) {
            assertThrows(DropFailure::class.java) { IncomingShare.read(invalid) }
        }
    }
    @Test fun realPinnedReceiverVerifiesThreeImagesAndClosesShare(): Unit = runBlocking {
        val raw = InstrumentationRegistry.getArguments().getString("fixture")
        Assume.assumeNotNull(raw)
        val fixture = JSONObject(raw!!)
        if (Build.VERSION.SDK_INT >= 37) instrumentation.uiAutomation.grantRuntimePermission(context.packageName,LAN_PERMISSION)
        val application = context.applicationContext as DropApplication
        val repository = DropRepository(context, ReceiverDiscovery { Endpoint(listOf(InetAddress.getByName("10.0.2.2")),fixture.getInt("port")) })
        application.repositoryOverride = repository
        var scenario: ActivityScenario<ShareActivity>? = null
        try {
            repository.pair(fixture.getString("pairing"))
            scenario = ActivityScenario.launch(share(3))
            val deadline = SystemClock.elapsedRealtime() + 20_000
            var capturedProgress = false
            while (scenario.state != Lifecycle.State.DESTROYED && SystemClock.elapsedRealtime() < deadline) {
                var workingAfterCommit = false
                scenario.onActivity {
                    val state = androidx.lifecycle.ViewModelProvider(it)[ShareViewModel::class.java].state.value
                    workingAfterCommit = state.working && state.committed
                }
                if (workingAfterCommit && !capturedProgress) {
                    instrumentation.waitForIdleSync(); SystemClock.sleep(120)
                    screenshot("share-progress.png"); capturedProgress = true
                }
                SystemClock.sleep(80)
            }
            if (scenario.state != Lifecycle.State.DESTROYED) {
                screenshot("transfer-failure.png")
                var detail = ""
                scenario.onActivity { detail = androidx.lifecycle.ViewModelProvider(it)[ShareViewModel::class.java].state.value.toString() }
                fail("Share stayed open: $detail")
            }
            val receipt = repository.latestReceipt() ?: error("Missing durable receipt")
            assertEquals(3, receipt.count)
            repository.connect(repository.pairing()!!).use { assertTrue(it.client.lookup(receipt.id).allVerified(3)) }
        } finally { scenario?.close(); repository.forget(); application.repositoryOverride = null }
    }
    @Test fun setupAndReviewRemainReadableAtLargeFont() {
        // Real Compose Activities with synthetic/unpaired data; no receiver connection.
        ActivityScenario.launch<MainActivity>(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)).use {
            instrumentation.waitForIdleSync(); SystemClock.sleep(800); screenshot("setup.png")
        }
        ActivityScenario.launch<ShareActivity>(share(1)).use {
            instrumentation.waitForIdleSync(); SystemClock.sleep(800); screenshot("share-review.png")
        }
    }
    private fun screenshot(name: String) {
        val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: error("Missing screenshot")
        try { File(context.getExternalFilesDir(null),name).outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) } }
        finally { bitmap.recycle() }
    }
}
