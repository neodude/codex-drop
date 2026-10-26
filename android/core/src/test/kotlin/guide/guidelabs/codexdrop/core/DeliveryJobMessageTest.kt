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
}
