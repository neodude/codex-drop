package guide.guidelabs.codexdrop.core

private fun supportedMediaMime(mime: String): Boolean = mime.startsWith("image/") ||
    mime in setOf("video/mp4", "video/quicktime", "video/*")

/** Wildcard SEND_MULTIPLE is how Android represents an ordered image/video selection. */
fun acceptsShareMime(mime: String?, multiple: Boolean): Boolean =
    mime != null && (supportedMediaMime(mime) || multiple && mime == "*/*")

/**
 * A provider may omit its type or expose originals as octet-stream. The receiver validates
 * the actual bytes, including video tracks and HEIC refusal, before any attachment occurs.
 * Never infer a supported format from a provider filename or alter its exported bytes.
 */
fun validateProviderMime(mime: String?) {
    if (mime == null || mime in setOf("application/octet-stream", "*/*") || supportedMediaMime(mime)) return
    throw DropFailure("Share JPEG, PNG, GIF, WebP, MP4 or MOV files. This app provided an unsupported file type.")
}
