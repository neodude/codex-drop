package guide.guidelabs.codexdrop.platform

import android.util.AtomicFile
import guide.guidelabs.codexdrop.core.DropFailure
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class PendingReceipt(val id: String, val count: Int, val service: String, val createdAtMillis: Long)
class ReceiptStore(private val directory: File) {
    private fun validate(id: String) {
        if (runCatching { UUID.fromString(id).toString() != id }.getOrDefault(true)) throw DropFailure("The stored receipt ID is invalid. Check Codex on your Mac.", true)
    }
    private fun write(name: String, data: ByteArray) {
        check(directory.isDirectory || directory.mkdirs())
        val file = AtomicFile(File(directory, name));val stream = file.startWrite()
        try { stream.write(data);file.finishWrite(stream) }
        catch (error: Exception) { file.failWrite(stream);throw error }
    }
    suspend fun save(receipt: PendingReceipt) = withContext(Dispatchers.IO) {
        validate(receipt.id);require(receipt.count in 1..10)
        val data = JSONObject().put("id",receipt.id).put("count",receipt.count).put("service",receipt.service).put("created",receipt.createdAtMillis).toString().toByteArray()
        write(receipt.id + ".json", data)
        write("latest",receipt.id.toByteArray())
    }
    suspend fun find(id: String): PendingReceipt? = withContext(Dispatchers.IO) {
        validate(id)
        val file = AtomicFile(File(directory,id + ".json"))
        if (!file.baseFile.exists()) return@withContext null
        try {
            val bytes = file.openRead().use { it.readLimited(2048) };require(bytes.size <= 2048)
            val json = JSONObject(bytes.decodeToString())
            PendingReceipt(json.getString("id"), json.getInt("count"), json.getString("service"), json.getLong("created")).also { require(it.id == id && it.count in 1..10) }
        } catch (_: Exception) { throw DropFailure("The stored receipt is unreadable. Check Codex before sharing again.", true) }
    }
    suspend fun latest(): PendingReceipt? = withContext(Dispatchers.IO) {
        val file = AtomicFile(File(directory,"latest"))
        if (!file.baseFile.exists()) return@withContext null
        val id = file.openRead().use { it.readLimited(36).decodeToString() }
        find(id)
    }
}
