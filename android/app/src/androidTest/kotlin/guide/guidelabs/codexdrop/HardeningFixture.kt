package guide.guidelabs.codexdrop

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import guide.guidelabs.codexdrop.core.*
import guide.guidelabs.codexdrop.platform.*
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import java.net.InetAddress

/** Real Activities and HTTPS, with disposable pairing and fake delivery only. */
abstract class HardeningFixture {
    val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    val context get() = instrumentation.targetContext
    lateinit var config: JSONObject
    lateinit var repository: DropRepository
    private val scenarios = mutableListOf<ActivityScenario<ShareActivity>>()
    @Before fun prepareFixture(): Unit = runBlocking {
        Assume.assumeTrue(Build.PRODUCT.contains("sdk"))
        val raw = InstrumentationRegistry.getArguments().getString("fixture")
        Assume.assumeNotNull(raw)
        config = JSONObject(raw!!)
        if (Build.VERSION.SDK_INT >= 37 && config.getString("mode") != "permission_denied")
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName,LAN_PERMISSION)
        java.io.File(context.noBackupFilesDir,"emulator-fixture.json").delete()
        repository = DropRepository(context, ReceiverDiscovery { endpoint() })
        (context.applicationContext as DropApplication).repositoryOverride = repository
        repository.forget()
        if (config.getString("mode") == "permission_denied") PairingStore(context).save(config.getString("pairing"))
        else repository.pair(config.getString("pairing"))
    }
    @After fun cleanFixture(): Unit = runBlocking {
        scenarios.asReversed().forEach { runCatching { it.close() } }
        if (::repository.isInitialized) repository.forget()
        (context.applicationContext as DropApplication).repositoryOverride = null
    }
    fun endpoint() = Endpoint(listOf(InetAddress.getByName("10.0.2.2")),config.getInt("port"))
    fun launch(count: Int = 3, source: String = "tiny.png"): Pair<ActivityScenario<ShareActivity>,ShareViewModel> {
        val uris = ArrayList((0 until count).map { Uri.parse("content://guide.guidelabs.codexdrop.test.images/$source") })
        val intent = Intent(context,ShareActivity::class.java).setAction(if (count == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE).setType("image/png").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if (count == 1) intent.putExtra(Intent.EXTRA_STREAM,uris[0]) else intent.putParcelableArrayListExtra(Intent.EXTRA_STREAM,uris)
        val scenario = ActivityScenario.launch<ShareActivity>(intent).also { scenarios += it }
        lateinit var model: ShareViewModel
        scenario.onActivity { model = ViewModelProvider(it)[ShareViewModel::class.java] }
        android.util.Log.i("DropTest", "launch returned " + model.requestId + " " + model.state.value)
        return scenario to model
    }
    fun waitFor(message: String, timeout: Long = 25_000, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (!predicate() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(40)
        assertTrue(message,predicate())
    }
    fun awaitClosed(scenario: ActivityScenario<ShareActivity>, model: ShareViewModel) {
        waitFor("Share did not verify") {
            val state = model.state.value
            if (!state.working && !state.finished) fail("Transfer stopped: $state")
            state.finished
        }
        waitFor("Verified share stayed open") { scenario.state == Lifecycle.State.DESTROYED }
    }
    fun close(model: ShareViewModel) = instrumentation.runOnMainSync { model.close() }
    fun awaitReview(model: ShareViewModel) { waitFor("Expected review: ${model.state.value}") { !model.state.value.working };assertFalse(model.state.value.finished) }
    suspend fun awaitVerified(id: String, count: Int) {
        repository.connect(repository.pairing()!!).use { connection ->
            val deadline = SystemClock.elapsedRealtime() + 20_000
            while (!connection.client.lookup(id).allVerified(count)) {
                if (SystemClock.elapsedRealtime() >= deadline) fail("Fixture delivery never verified")
                kotlinx.coroutines.delay(100)
            }
        }
    }
}
