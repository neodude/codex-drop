package guide.guidelabs.codexdrop

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Build
import guide.guidelabs.codexdrop.core.Endpoint
import guide.guidelabs.codexdrop.platform.ReceiverDiscovery
import org.json.JSONObject
import java.io.File
import java.net.InetAddress

/** Debug/emulator only. Private endpoint override keeps real TLS pin/token validation intact. */
class EmulatorFixtureProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        if (!Build.PRODUCT.startsWith("sdk") || Build.HARDWARE !in setOf("ranchu","goldfish")) return true
        val app = context?.applicationContext as? DropApplication ?: return true
        val file = File(app.noBackupFilesDir,"emulator-fixture.json")
        if (!file.isFile || file.length() !in 2..128) return true
        val fixture = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return true
        val port = fixture.optInt("port")
        val host = fixture.optString("host", "10.0.2.2")
        if (port !in 1..65535 || host !in setOf("10.0.2.2", "127.0.0.1")) return true
        app.repositoryOverride = DropRepository(app, ReceiverDiscovery {
            Endpoint(listOf(InetAddress.getByName(host)),port)
        })
        return true
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, order: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = throw UnsupportedOperationException()
}
