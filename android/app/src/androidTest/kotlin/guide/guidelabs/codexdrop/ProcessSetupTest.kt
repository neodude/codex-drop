package guide.guidelabs.codexdrop

import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import guide.guidelabs.codexdrop.core.Endpoint
import guide.guidelabs.codexdrop.platform.ReceiverDiscovery
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.*
import org.junit.runner.RunWith
import java.io.File
import java.net.InetAddress

@RunWith(AndroidJUnit4::class)
class ProcessSetupTest {
    @Test fun preparePrivateEmulatorEndpointAndPairing(): Unit = runBlocking {
        Assume.assumeTrue(Build.PRODUCT.startsWith("sdk") && Build.HARDWARE in setOf("ranchu","goldfish"))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val fixture = JSONObject(InstrumentationRegistry.getArguments().getString("fixture")!!)
        if (Build.VERSION.SDK_INT >= 37) instrumentation.uiAutomation.grantRuntimePermission(context.packageName,LAN_PERMISSION)
        File(context.noBackupFilesDir,"emulator-fixture.json").writeText(JSONObject().put("port",fixture.getInt("port")).toString())
        val repository = DropRepository(context,ReceiverDiscovery { Endpoint(listOf(InetAddress.getByName("10.0.2.2")),fixture.getInt("port")) })
        repository.pair(fixture.getString("pairing"))
    }
}
