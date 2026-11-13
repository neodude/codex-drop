package guide.guidelabs.codexdrop.core

import org.junit.Assert.*
import org.junit.Test

class DeliveryJobMessageTest {
    @Test fun lockedMacExplainsHowToRecoverWithoutRetrying() {
        val job = DeliveryJob(TEST_ID, "blocked", listOf(DeliveryItem(0,"blocked",false,"mac_screen_locked")),0,1,"mac_screen_locked")
        val message = job.reviewMessage()
        assertTrue(message.startsWith("Unlock your Mac"))
        assertTrue(message.contains("0 of 1"))
        assertTrue(message.contains("No automatic retry"))
        assertFalse(job.allVerified(1))
    }
    @Test fun lockAfterOneAttachmentPreservesPartialWarning() {
        val job = DeliveryJob(TEST_ID, "uncertain", listOf(DeliveryItem(0,"verified",true,null),DeliveryItem(1,"blocked",false,"mac_screen_locked")),1,2,"batch_stopped")
        val message = job.reviewMessage()
        assertTrue(message.startsWith("Unlock your Mac"))
        assertTrue(message.contains("1 of 2"))
        assertTrue(message.contains("Don’t resend files already attached"))
    }
    @Test fun missingResultCanExplainLockWithoutClaimingAttachment() {
        val job = DeliveryJob(TEST_ID,"blocked",null,null,null,"mac_screen_locked")
        assertTrue(job.reviewMessage().startsWith("Unlock your Mac"))
        assertTrue(job.reviewMessage().contains("not confirmed"))
        assertFalse(job.allVerified(1))
    }
    @Test fun draftChangeBeforePasteExplainsTheStop() {
        val job = DeliveryJob(TEST_ID,"blocked",listOf(DeliveryItem(0,"blocked",false,"batch_draft_changed")),0,1,"batch_draft_changed")
        assertTrue(job.stoppedBeforeAttachment(1))
        assertFalse(job.stoppedBeforeAttachment(2))
        assertTrue(job.reviewMessage().contains("change in the Mac’s draft"))
        assertTrue(job.reviewMessage().contains("blocked before attachment"))
        assertTrue(job.reviewMessage().contains("No automatic retry"))
    }
    @Test fun partialOrUnconfirmedSharesCannotClaimNothingWasAttached() {
        val partial = DeliveryJob(TEST_ID,"uncertain",listOf(DeliveryItem(0,"verified",true,null),DeliveryItem(1,"blocked",false,"batch_draft_changed")),1,2,"batch_stopped")
        val unknown = DeliveryJob(TEST_ID,"blocked",listOf(DeliveryItem(0,"blocked",null,"batch_draft_changed")),0,1,"batch_draft_changed")
        assertFalse(partial.stoppedBeforeAttachment(2))
        assertFalse(unknown.stoppedBeforeAttachment(1))
    }
}
