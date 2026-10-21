package guide.guidelabs.codexdrop

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class StressHardeningTest : HardeningFixture() {
    @Test fun tenRealImagesAreVerifiedInOneBatch(): Unit = runBlocking {
        val (scenario,model) = launch(10,"noise.png")
        awaitClosed(scenario,model)
        val saved = repository.latestReceipt()!!
        assertEquals(10,saved.count);assertEquals(model.requestId,saved.id)
        awaitVerified(saved.id,10)
    }
    @Test fun fiveConsecutiveSharesUseFreshIds(): Unit = runBlocking {
        val ids = mutableSetOf<String>()
        repeat(5) {
            val (scenario,model) = launch(3)
            awaitClosed(scenario,model);assertTrue(ids.add(model.requestId))
            awaitVerified(model.requestId,3)
        }
    }
}
