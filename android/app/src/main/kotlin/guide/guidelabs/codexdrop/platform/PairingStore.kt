package guide.guidelabs.codexdrop.platform

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import guide.guidelabs.codexdrop.core.DropFailure
import guide.guidelabs.codexdrop.core.Pairing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class PairingStore(context: Context, name: String = "receiver") {
    init { require(name.matches(Regex("[A-Za-z0-9-]{1,80}"))) }
    private val file = AtomicFile(File(context.noBackupFilesDir, "$name.enc"))
    private val alias = "CodexDrop.Pairing.$name"
    fun exists() = file.baseFile.exists()
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).setUnlockedDeviceRequired(true).build())
        }.generateKey()
    }
    suspend fun load(): Pairing? = withContext(Dispatchers.IO) {
        if (!exists()) return@withContext null
        try {
            val bytes = file.openRead().use { input ->
                val data = input.readLimited(4096)
                require(data.size <= 4096);data
            }
            require(bytes.size >= 30 && bytes[0] == 1.toByte() && bytes[1] == 12.toByte())
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(2,14)))
            Pairing.parse(cipher.doFinal(bytes.copyOfRange(14, bytes.size)).decodeToString())
        } catch (_: Exception) { throw DropFailure("Couldn’t unlock this phone’s pairing. Forget it in Codex Drop, then pair again.") }
    }
    suspend fun save(code: String) = withContext(Dispatchers.IO) {
        Pairing.parse(code)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val encrypted = byteArrayOf(1,12) + cipher.iv + cipher.doFinal(code.trim().toByteArray())
        val output = file.startWrite()
        try { output.write(encrypted);file.finishWrite(output) }
        catch (error: Exception) { file.failWrite(output);throw error }
    }
    suspend fun forget() = withContext(Dispatchers.IO) {
        file.delete()
        KeyStore.getInstance("AndroidKeyStore").apply { load(null);deleteEntry(alias) }
    }
}
