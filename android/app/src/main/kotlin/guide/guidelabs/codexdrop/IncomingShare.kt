package guide.guidelabs.codexdrop

import android.content.Intent
import android.net.Uri
import android.os.Build
import guide.guidelabs.codexdrop.core.DropFailure
import guide.guidelabs.codexdrop.core.acceptsShareMime

object IncomingShare {
    @Suppress("DEPRECATION")
    fun read(intent: Intent): List<String> {
        try {
            if (intent.action !in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE) || !acceptsShareMime(intent.type, intent.action == Intent.ACTION_SEND_MULTIPLE))
                throw DropFailure("Share photos or MP4/MOV videos to Codex Drop.")
            val uris: List<Uri> = if (intent.hasExtra(Intent.EXTRA_STREAM)) {
                if (intent.action == Intent.ACTION_SEND) {
                    listOfNotNull(if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
                } else {
                    (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)).orEmpty()
                }
            } else {
                val clip = intent.clipData
                if (clip == null || clip.itemCount !in 1..10) emptyList() else (0 until clip.itemCount).map { clip.getItemAt(it).uri ?: throw DropFailure("This share contains an unreadable file.") }
            }
            if (uris.size !in 1..10) throw DropFailure("Choose between 1 and 10 files for each share.")
            if (uris.any { it.scheme != "content" }) throw DropFailure("This app didn’t provide a supported file. Try sharing from Photos, Files or the screenshot preview.")
            return uris.map(Uri::toString)
        } catch (error: DropFailure) { throw error }
        catch (_: Exception) { throw DropFailure("This app didn’t provide readable files. Try sharing from Photos, Files or the screenshot preview.") }
    }
}
