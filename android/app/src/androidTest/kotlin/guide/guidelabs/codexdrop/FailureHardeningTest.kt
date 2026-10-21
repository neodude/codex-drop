package guide.guidelabs.codexdrop

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FailureHardeningTest : HardeningFixture() {
    @Test fun interruptedUploadOrConfirmationNeverResends(): Unit = runBlocking {
        val mode = config.getString("mode")
        val (_,model) = launch()
        awaitReview(model)
        if (mode == "upload_lost") {
            assertFalse(model.state.value.committed)
            assertNull(repository.receipt(model.requestId))
        } else {
            assertTrue(model.state.value.committed);assertTrue(model.state.value.canCheck)
            assertEquals(model.requestId,repository.latestReceipt()!!.id)
            if (mode == "commit_lost") {
                awaitVerified(model.requestId,3)
                instrumentation.runOnMainSync { model.checkReceipt() }
                waitFor("Explicit receipt lookup did not finish") { model.state.value.finished }
            }
        }
        close(model)
    }
}
@RunWith(AndroidJUnit4::class)
class PartialHardeningTest : HardeningFixture() {
    @Test fun partialOrBlockedResultStaysOpenAndDoesNotBlockANewShare(): Unit = runBlocking {
        val (_,first) = launch(3)
        awaitReview(first)
        assertTrue(first.state.value.toString(),first.state.value.detail.contains(if (config.getString("mode") == "partial_first") "1 of 3" else "0 of 3"))
        assertTrue(first.state.value.canCheck)
        val (scenario,second) = launch(2)
        awaitClosed(scenario,second)
        assertNotEquals(first.requestId,second.requestId)
        assertFalse(first.state.value.finished)
        awaitVerified(second.requestId,2)
        close(first)
    }
}
