package guide.guidelabs.codexdrop.core

import org.junit.Assert.*
import org.junit.Test

class SharedMediaTest {
    @Test fun mp4AndQuickTimeSharesAreAccepted() {
        for (mime in listOf("video/mp4", "video/quicktime", "video/*")) {
            assertTrue("Single $mime", acceptsShareMime(mime, false))
            assertTrue("Multiple $mime", acceptsShareMime(mime, true))
        }
    }
    @Test fun mixedSharesUseWildcardOnlyForMultipleItems() {
        assertTrue(acceptsShareMime("*/*", true))
        assertFalse(acceptsShareMime("*/*", false))
    }
    @Test fun existingImageSharesRemainAcceptedAndOtherTypesAreRefused() {
        for (mime in listOf("image/png", "image/jpeg", "image/heic", "image/*")) assertTrue(acceptsShareMime(mime, false))
        for (mime in listOf(null, "text/plain", "application/pdf", "audio/mp4", "video/webm")) assertFalse(acceptsShareMime(mime, true))
    }
    @Test fun eachProviderMimeIsCheckedIncludingMixedAndUnknownProviders() {
        for (mime in listOf(null, "application/octet-stream", "*/*", "image/heic", "image/jpeg", "video/mp4", "video/quicktime", "video/*")) validateProviderMime(mime)
        for (mime in listOf("text/plain", "application/pdf", "audio/mp4", "video/webm", "video/avi")) {
            assertThrows(DropFailure::class.java) { validateProviderMime(mime) }
        }
    }
}
