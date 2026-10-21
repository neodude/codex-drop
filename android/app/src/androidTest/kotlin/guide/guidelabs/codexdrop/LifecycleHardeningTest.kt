package guide.guidelabs.codexdrop

import android.content.pm.ActivityInfo
import android.os.SystemClock
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import android.net.Uri
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class LifecycleHardeningTest : HardeningFixture() {
    @Test fun recreationWhileReadingKeepsTheSameTransfer() {
        val gate = "gated-${UUID.randomUUID()}.png"
        val (scenario,model) = launch(2,gate)
        waitFor("Image never began reading") {
            val state = model.state.value
            if (!state.working || state.finished) fail("Unexpected before-read state: $state")
            state.stage == 1
        }
        val id = model.requestId
        scenario.recreate()
        scenario.onActivity { assertSame(model,ViewModelProvider(it)[ShareViewModel::class.java]);assertEquals(id,ViewModelProvider(it)[ShareViewModel::class.java].requestId) }
        context.contentResolver.call(Uri.parse("content://guide.guidelabs.codexdrop.test.images"),"release",gate,null)
        awaitClosed(scenario,model)
    }
    @Test fun rotationAndBackgroundAfterCommitDoNotReplay() {
        val (scenario,model) = launch()
        waitFor("Commit never started") { model.state.value.committed }
        val id = model.requestId
        scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
        instrumentation.waitForIdleSync()
        scenario.moveToState(Lifecycle.State.CREATED)
        SystemClock.sleep(200)
        if (!model.state.value.finished && scenario.state != Lifecycle.State.DESTROYED) {
            try { scenario.moveToState(Lifecycle.State.RESUMED) }
            catch (error: AssertionError) { if (!model.state.value.finished) throw error }
        }
        assertEquals(id,model.requestId)
        awaitClosed(scenario,model)
    }
    @Test fun simultaneousShareIsRefusedAndCancelBeforeCommitStopsDelivery() {
        val gate = "gated-${UUID.randomUUID()}.png"
        val (first,model) = launch(2,gate)
        waitFor("Image never began reading") {
            val state = model.state.value
            if (!state.working || state.finished) fail("Unexpected before-read state: $state")
            state.stage == 1
        }
        val (second,other) = launch(1)
        awaitReview(other)
        assertEquals("Another share is in progress",other.state.value.title)
        close(other);close(model)
        context.contentResolver.call(Uri.parse("content://guide.guidelabs.codexdrop.test.images"),"release",gate,null)
        waitFor("Cancelled first share stayed open") { first.state == Lifecycle.State.DESTROYED }
        waitFor("Refused second share stayed open") { second.state == Lifecycle.State.DESTROYED }
        assertFalse(model.state.value.committed)
    }
    @Test fun closingAfterCommitLeavesOneRecoverableReceipt(): Unit = runBlocking {
        val (_,model) = launch()
        waitFor("Commit never started") { model.state.value.committed }
        close(model)
        assertEquals(model.requestId,repository.latestReceipt()!!.id)
        awaitVerified(model.requestId,3)
    }
}
