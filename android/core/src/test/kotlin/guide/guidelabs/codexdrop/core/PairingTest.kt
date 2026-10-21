package guide.guidelabs.codexdrop.core

import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class PairingTest {
    private val service = "CodexShot-12345678-1234-1234-1234-123456789abc"
    private fun code(json: String) = "codexshot://pair?data=" + Base64.getUrlEncoder().withoutPadding().encodeToString(json.toByteArray())
    private fun json(v: String = "1", pin: String = "a".repeat(64), token: String = "b".repeat(43)) = """{"v":$v,"service":"$service","pin":"$pin","token":"$token"}"""
    @Test fun parsesExistingMacQrWithoutChangingIdentity() {
        val pairing = Pairing.parse(code(json()))
        assertEquals(service, pairing.service)
        assertEquals("a".repeat(64), pairing.pin)
        assertEquals("b".repeat(43), pairing.token)
        assertFalse(pairing.toString().contains("b".repeat(43)))
    }
    @Test fun rejectsMalformedAndAmbiguousCodes() {
        val valid = code(json())
        listOf(valid + "&data=again", valid + "#fragment", valid.replace("//pair", "//user@pair"),
            valid.replace("//pair?", "//pair/?"), valid.replace("codexshot:", "https:"),
            code(json(v = "2")), code(json(pin = "A".repeat(64))), code(json(token = "short")),
            code(json().replace("\"v\":1", "\"v\":null,\"v\":1")),
            code(json().replace(service, service.uppercase())), "codexshot://pair?data=" + "a".repeat(2049)
        ).forEach { value -> assertThrows(DropFailure::class.java) { Pairing.parse(value) } }
    }
}
