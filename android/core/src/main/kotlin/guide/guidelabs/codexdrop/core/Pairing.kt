package guide.guidelabs.codexdrop.core

import com.squareup.moshi.JsonReader
import okio.Buffer
import java.math.BigDecimal
import java.net.URI
import java.util.Base64

class DropFailure(message: String, val mayBeAttached: Boolean = false) : Exception(message)

/** Never include the bearer token or complete QR in diagnostics. */
data class Pairing(val service: String, val pin: String, val token: String) {
    init {
        if (!service.matches(Regex("CodexShot-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")) ||
            !pin.matches(Regex("[0-9a-f]{64}")) || !token.matches(Regex("[A-Za-z0-9_-]{43}"))) throw DropFailure("This pairing code has an unsupported format.")
    }
    override fun toString() = "Pairing(service=$service, credentials=[redacted])"
    companion object {
        fun parse(text: String): Pairing = try {
            val uri = URI(text.trim())
            val query = uri.rawQuery ?: ""
            if (uri.scheme != "codexshot" || uri.rawAuthority != "pair" || !uri.rawPath.isNullOrEmpty() || uri.rawFragment != null || !query.startsWith("data=")) throw IllegalArgumentException()
            val encoded = query.removePrefix("data=")
            if (encoded.length !in 1..2048 || !encoded.matches(Regex("[A-Za-z0-9_-]+"))) throw IllegalArgumentException()
            val fields = StrictJson.objectValue(Base64.getUrlDecoder().decode(encoded))
            if (fields.keys != setOf("v", "service", "pin", "token") || fields.int("v") != 1) throw IllegalArgumentException()
            Pairing(fields.string("service"), fields.string("pin"), fields.string("token"))
        } catch (_: Exception) { throw DropFailure("This is not a valid Codex Drop pairing code.") }
    }
}

/** Reject duplicate keys and excessive nesting rather than accepting ambiguous receipts. */
internal object StrictJson {
    fun objectValue(bytes: ByteArray): Map<String, Any?> {
        require(bytes.size in 2..65_536)
        JsonReader.of(Buffer().write(bytes)).use { reader ->
            var nodes = 0
            fun value(depth: Int): Any? {
                require(depth <= 16 && ++nodes <= 8192)
                return when (reader.peek()) {
                    JsonReader.Token.BEGIN_OBJECT -> {
                        val map = linkedMapOf<String, Any?>(); reader.beginObject()
                        while (reader.hasNext()) {
                            val name = reader.nextName(); require(!map.containsKey(name))
                            map[name] = value(depth + 1)
                        }
                        reader.endObject(); map
                    }
                    JsonReader.Token.BEGIN_ARRAY -> {
                        val list = mutableListOf<Any?>(); reader.beginArray()
                        while (reader.hasNext()) { require(list.size < 512); list += value(depth + 1) }
                        reader.endArray(); list
                    }
                    JsonReader.Token.STRING -> reader.nextString()
                    JsonReader.Token.NUMBER -> BigDecimal(reader.nextString())
                    JsonReader.Token.BOOLEAN -> reader.nextBoolean()
                    JsonReader.Token.NULL -> reader.nextNull<Any>()
                    else -> throw IllegalArgumentException()
                }
            }
            @Suppress("UNCHECKED_CAST") val result = value(0) as? Map<String, Any?> ?: throw IllegalArgumentException()
            require(reader.peek() == JsonReader.Token.END_DOCUMENT)
            return result
        }
    }
}
internal fun Map<String, Any?>.string(name: String) = this[name] as? String ?: throw IllegalArgumentException()
internal fun Map<String, Any?>.int(name: String) = (this[name] as? BigDecimal)?.intValueExact() ?: throw IllegalArgumentException()
