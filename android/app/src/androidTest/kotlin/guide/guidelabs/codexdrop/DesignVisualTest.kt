package guide.guidelabs.codexdrop

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Renders production composables with explicit inert state; never uses a receiver. */
class DesignVisualTest {
    @get:Rule val compose = createAndroidComposeRule<DesignPreviewActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun SemanticsNodeInteraction.reveal(): SemanticsNodeInteraction =
        if (InstrumentationRegistry.getArguments().getString("capturePrefix").orEmpty().startsWith("baseline")) this else performScrollTo()
    private fun capture(name: String) {
        if (!name.endsWith("actions")) compose.onNodeWithText("Codex Drop").reveal()
        compose.waitForIdle()
        android.os.SystemClock.sleep(450) // Let native touch ripples settle before capture.
        val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: error("Missing screenshot")
        val prefix = InstrumentationRegistry.getArguments().getString("capturePrefix") ?: "design"
        try { File(compose.activity.filesDir, "$prefix-$name.png").outputStream().use {
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        } } finally { bitmap.recycle() }
    }
    @Test fun setupStatesAndConfirmedForget() {
        val state = MutableStateFlow(SetupState())
        var pair = 0; var check = 0; var forget = 0; var receipt = 0
        compose.setContent { DropTheme { SetupScreen(state, { pair++ }, { check++ }, { forget++ }, { receipt++ }) } }
        capture("unpaired")
        compose.onNodeWithText("Pair your Mac").reveal().assertIsDisplayed().performClick()
        assertEquals(1, pair)
        capture("unpaired-actions")
        compose.runOnIdle { state.value = SetupState(paired = true, message = "Connected to your Mac. Ready to share images to Codex.") }
        capture("paired")
        compose.onNodeWithText("Check connection").reveal().assertIsDisplayed().performClick()
        assertEquals(1, check)
        compose.onNodeWithText("Pair another Mac").reveal().performClick()
        assertEquals(2, pair)
        compose.onNodeWithText("Check last share").reveal().performClick()
        assertEquals(1, receipt)
        compose.onNodeWithText("Forget pairing").reveal().assertIsDisplayed()
        capture("paired-actions")
        compose.onNodeWithText("Forget pairing").performClick()
        compose.onNodeWithText("Forget this Mac?").assertIsDisplayed()
        assertEquals(0, forget)
        compose.onNodeWithText("Cancel").performClick()
        assertEquals(0, forget)
        compose.onNodeWithText("Forget pairing").performClick()
        compose.onNodeWithText("Forget", substring = false).performClick()
        assertEquals(1, forget)
    }
    @Test fun shareStatesKeepPreciseMessagesAndActions() {
        val state = MutableStateFlow(ShareUiState())
        var close = 0; var check = 0; var open = 0
        compose.setContent { DropTheme { ShareScreen(state, { close++ }, { check++ }, { open++ }) } }
        capture("finding")
        compose.onNodeWithText("Cancel").reveal().assertIsDisplayed().performClick()
        assertEquals(1, close)
        capture("finding-actions")
        compose.runOnIdle { state.value = ShareUiState("Sending image 2 of 3", "Transferring securely to your Mac…", 1) }
        capture("transfer")
        compose.onNodeWithText("Cancel").reveal().assertIsDisplayed()
        capture("transfer-actions")
        compose.runOnIdle { state.value = ShareUiState("Checking attachments", "Waiting for the Mac to verify your draft…", 2, committed = true) }
        capture("progress")
        compose.onNodeWithText("Cancel").assertDoesNotExist()
        compose.onNodeWithText("Close").reveal().assertIsDisplayed()
        capture("progress-actions")
        compose.runOnIdle { state.value = ShareUiState("Couldn’t attach", "Open Codex Drop and scan the Mac’s pairing QR code first.", working = false) }
        capture("review")
        compose.onNodeWithText("Open Codex Drop").reveal().assertIsDisplayed().performClick()
        assertEquals(1, open)
        val detail = guide.guidelabs.codexdrop.core.DeliveryJob(
            "00000000-0000-4000-8000-000000000000", "uncertain",
            listOf(guide.guidelabs.codexdrop.core.DeliveryItem(0, "verified", true, null),
                guide.guidelabs.codexdrop.core.DeliveryItem(1, "uncertain", true, null),
                guide.guidelabs.codexdrop.core.DeliveryItem(2, "not_attempted", false, null)),
            1, 3, "batch_stopped").reviewMessage()
        compose.runOnIdle { state.value = ShareUiState("Check your Mac", detail, 2, working = false, committed = true, canCheck = true) }
        compose.onNodeWithText(detail).assertExists()
        capture("partial")
        compose.onNodeWithText("Open Codex Drop").assertDoesNotExist()
        compose.onNodeWithText("Check receipt").reveal().assertIsDisplayed().performClick()
        assertEquals(1, check)
        compose.onNodeWithText("Close").reveal().assertIsDisplayed()
        capture("partial-actions")
    }
}
