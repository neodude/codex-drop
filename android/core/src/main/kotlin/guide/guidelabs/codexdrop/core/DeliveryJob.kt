package guide.guidelabs.codexdrop.core

import java.util.UUID

internal fun validId(value: String): Boolean = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)
data class DeliveryItem(val index: Int, val status: String, val pasteAttempted: Boolean?, val reason: String?)
data class DeliveryJob(val id: String, val state: String, val items: List<DeliveryItem>?, val verifiedCount: Int?, val totalCount: Int?, val reason: String?) {
    fun allVerified(count: Int): Boolean = state == "verified" && totalCount == count && verifiedCount == count &&
        items?.size == count && items.map { it.index }.sorted() == (0 until count).toList() && items.all { it.status == "verified" }
    fun reviewMessage(): String {
        val detail = if (items == null || totalCount == null || verifiedCount == null) "Attachment is not confirmed. Check Codex on your Mac before sharing again." else buildString {
            append("$verifiedCount of $totalCount files verified attached.")
            items.filter { it.status != "verified" }.forEach { item ->
                append("\nFile ${item.index + 1}: ")
                append(when (item.status) {
                    "uncertain" -> "uncertain; it may already be attached."
                    "blocked" -> if (item.pasteAttempted == false) "blocked before attachment." else "unconfirmed; check your Mac."
                    else -> "not tried."
                })
            }
        }
        val permission = if (reason == "accessibility_permission_required" || items?.any { it.reason == "accessibility_permission_required" } == true)
            "\nAllow Codex Drop in Mac System Settings → Privacy & Security → Accessibility." else ""
        val unlock = if (reason == "mac_screen_locked" || items?.any { it.reason == "mac_screen_locked" } == true)
            "Unlock your Mac to attach files.\n" else ""
        return "$unlock$detail$permission\nDon’t resend files already attached. No automatic retry."
    }
    companion object {
        internal fun parse(fields: Map<String, Any?>): DeliveryJob {
            val id = fields.string("id"); require(validId(id))
            val state = fields.string("state"); require(state in setOf("uploading", "queued", "running", "verified", "blocked", "uncertain", "dismissed"))
            @Suppress("UNCHECKED_CAST") val result = fields["result"] as? Map<String, Any?>
            val rawItems = result?.get("items") as? List<*>
            if (rawItems == null) {
                require(state != "verified")
                return DeliveryJob(id, state, null, null, null, result?.get("reason") as? String)
            }
            val total = result.int("totalCount"); val verified = result.int("verifiedCount")
            require(total in 1..10 && verified in 0..total && rawItems.size == total)
            val items = rawItems.map { raw ->
                @Suppress("UNCHECKED_CAST") val item = raw as? Map<String, Any?> ?: throw IllegalArgumentException()
                val status = item.string("status"); require(status in setOf("verified", "blocked", "uncertain", "not_attempted"))
                DeliveryItem(item.int("index"), status, item["pasteAttempted"] as? Boolean, item["reason"] as? String)
            }.sortedBy { it.index }
            require(items.map { it.index } == (0 until total).toList() && items.count { it.status == "verified" } == verified)
            var stopped = false
            for (item in items) {
                if (stopped) require(item.status == "not_attempted")
                if (item.status != "verified") stopped = true
            }
            require((state == "verified") == (verified == total))
            return DeliveryJob(id, state, items, verified, total, result["reason"] as? String)
        }
    }
}
