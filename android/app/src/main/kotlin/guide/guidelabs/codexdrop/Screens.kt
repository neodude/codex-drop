package guide.guidelabs.codexdrop

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.flow.StateFlow

private val Ink = Color(0xFFF4F4F7)
private val Muted = Color(0xFF9B9BA7)
private val Blue = Color(0xFFB3B9FF)
@Composable fun DropTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = darkColorScheme(primary = Blue, onPrimary = Color(0xFF191B43), background = Color(0xFF101014), surface = Color(0xFF1B1B22), onSurface = Ink), content = content)
}
@Composable private fun Brand() {
    Image(painterResource(R.drawable.drop_mark), contentDescription = null, Modifier.size(94.dp))
    Spacer(Modifier.height(22.dp))
    Text("Codex Drop", fontSize = 29.sp, fontWeight = FontWeight.SemiBold, color = Ink)
}
@Composable private fun Frame(content: @Composable ColumnScope.() -> Unit, buttons: @Composable ColumnScope.() -> Unit) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = 28.dp)) {
            Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(top = 46.dp, bottom = 24.dp), horizontalAlignment = Alignment.CenterHorizontally, content = content)
            Column(Modifier.fillMaxWidth().padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = buttons)
        }
    }
}
@Composable fun ShareScreen(stateFlow: StateFlow<ShareUiState>, onClose: () -> Unit, onReceipt: () -> Unit, onSetup: () -> Unit) {
    val state by stateFlow.collectAsStateWithLifecycle()
    Frame(content = {
        Brand()
        Spacer(Modifier.height(40.dp))
        Text(state.title, fontSize = 23.sp, fontWeight = FontWeight.Medium, color = Ink)
        Spacer(Modifier.height(14.dp))
        Text(state.detail, color = Muted, lineHeight = 25.sp, modifier = Modifier.fillMaxWidth())
        if (state.working) {
            Spacer(Modifier.height(34.dp))
            Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface, RoundedCornerShape(20.dp)).padding(20.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                listOf("Find your Mac", "Transfer images", "Attach to draft").forEachIndexed { index, label ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (index == state.stage) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Blue)
                        else Text(if (index < state.stage) "✓" else "○", color = if (index < state.stage) Blue else Muted, modifier = Modifier.width(18.dp))
                        Spacer(Modifier.width(14.dp))
                        Text(label, color = if (index <= state.stage) Ink else Muted)
                    }
                }
            }
        }
    }, buttons = {
        if (!state.working && state.canCheck) Button(onReceipt, Modifier.fillMaxWidth().heightIn(min = 52.dp)) { Text("Check receipt") }
        if (!state.working && !state.committed) OutlinedButton(onSetup, Modifier.fillMaxWidth().heightIn(min = 52.dp)) { Text("Open Codex Drop") }
        TextButton(onClose, Modifier.fillMaxWidth().heightIn(min = 52.dp)) { Text(if (state.working && !state.committed) "Cancel" else "Close", color = Muted) }
    })
}
@Composable fun SetupScreen(stateFlow: StateFlow<SetupState>, onPair: () -> Unit, onCheck: () -> Unit, onForget: () -> Unit, onReceipt: () -> Unit) {
    val state by stateFlow.collectAsStateWithLifecycle()
    var confirmForget by remember { mutableStateOf(false) }
    Frame(content = {
        Brand(); Spacer(Modifier.height(34.dp))
        Text(if (state.paired) "Your Mac, one share away." else "Screenshots. Straight to Codex.", fontSize = 24.sp, fontWeight = FontWeight.Medium, color = Ink)
        Spacer(Modifier.height(18.dp))
        Text(state.message, lineHeight = 25.sp, color = Muted, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(26.dp))
        if (state.busy) CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
        Spacer(Modifier.height(20.dp))
        Text("1. Keep Codex Drop running on your Mac.\n2. Use the same Wi-Fi on both devices.\n3. Share 1–10 images → Codex Drop.", lineHeight = 28.sp, color = Muted, modifier = Modifier.fillMaxWidth())
    }, buttons = {
        Button(onPair, Modifier.fillMaxWidth().heightIn(min = 54.dp), enabled = !state.busy) { Text(if (state.paired) "Pair another Mac" else "Pair your Mac") }
        if (state.paired) {
            OutlinedButton(onCheck, Modifier.fillMaxWidth().heightIn(min = 50.dp), enabled = !state.busy) { Text("Check connection") }
            TextButton(onReceipt, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = !state.busy) { Text("Check last share") }
            TextButton({ confirmForget = true }, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = !state.busy) { Text("Forget pairing", color = Muted) }
        }
    })
    if (confirmForget) AlertDialog(onDismissRequest = { confirmForget = false }, title = { Text("Forget this Mac?") }, text = { Text("You’ll need to scan its pairing QR code before sharing again.") }, confirmButton = { TextButton({ confirmForget = false; onForget() }) { Text("Forget") } }, dismissButton = { TextButton({ confirmForget = false }) { Text("Cancel") } })
}
