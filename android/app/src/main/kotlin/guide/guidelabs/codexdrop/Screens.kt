package guide.guidelabs.codexdrop

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
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
private val Muted = Color(0xFFB3B3BF)
private val Aquamarine = Color(0xFF2FFFD3)
private val Mint = Color(0xFF69D5C1)

@Composable fun DropTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = darkColorScheme(
        primary = Aquamarine, onPrimary = Color(0xFF062B24),
        background = Color(0xFF101014), onBackground = Ink,
        surface = Color(0xFF1B1B22), onSurface = Ink,
        onSurfaceVariant = Muted, outline = Color(0xFF777782),
    ), content = content)
}

@Composable private fun Brand() {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Image(painterResource(R.drawable.drop_mark), contentDescription = null, Modifier.size(94.dp))
        Spacer(Modifier.height(18.dp))
        Text("Codex Drop", fontSize = 29.sp, lineHeight = 35.sp, fontWeight = FontWeight.SemiBold, color = Ink)
    }
}

@Composable private fun Frame(content: @Composable ColumnScope.() -> Unit, buttons: @Composable ColumnScope.() -> Unit) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding()) {
            // One scroll area keeps every action reachable with large text or a compact window.
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .heightIn(min = maxHeight).padding(horizontal = 28.dp).padding(top = 32.dp, bottom = 20.dp)) {
                Column(Modifier.fillMaxWidth(), content = content)
                Spacer(Modifier.height(28.dp))
                Spacer(Modifier.weight(1f))
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp), content = buttons)
            }
        }
    }
}

@Composable private fun Heading(title: String, detail: String) {
    Text(title, fontSize = 23.sp, lineHeight = 29.sp, fontWeight = FontWeight.Medium, color = Ink)
    Spacer(Modifier.height(12.dp))
    Text(detail, color = Muted, lineHeight = 25.sp, modifier = Modifier.fillMaxWidth())
}

@Composable private fun TransferStages(stage: Int) {
    Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface, RoundedCornerShape(20.dp))
        .padding(20.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        listOf("Find your Mac", "Transfer images", "Attach to draft").forEachIndexed { index, label ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                when {
                    index < stage -> Icon(Icons.Filled.CheckCircle, "Completed", Modifier.size(20.dp), tint = Mint)
                    index == stage -> CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Aquamarine)
                    else -> RadioButton(selected = false, onClick = null, enabled = false, modifier = Modifier.size(20.dp),
                        colors = RadioButtonDefaults.colors(disabledUnselectedColor = Muted))
                }
                Spacer(Modifier.width(14.dp))
                Text(label, color = if (index <= stage) Ink else Muted, modifier = Modifier.weight(1f))
            }
        }
    }
}

@Composable fun ShareScreen(stateFlow: StateFlow<ShareUiState>, onClose: () -> Unit, onReceipt: () -> Unit, onSetup: () -> Unit) {
    val state by stateFlow.collectAsStateWithLifecycle()
    Frame(content = {
        Brand()
        Spacer(Modifier.height(32.dp))
        Heading(state.title, state.detail)
        if (state.working) {
            Spacer(Modifier.height(28.dp))
            TransferStages(state.stage)
        }
    }, buttons = {
        if (!state.working && state.canCheck) Button(onReceipt, Modifier.fillMaxWidth().heightIn(min = 54.dp)) { Text("Check receipt") }
        if (!state.working && !state.committed) OutlinedButton(onSetup, Modifier.fillMaxWidth().heightIn(min = 54.dp)) { Text("Open Codex Drop") }
        TextButton(onClose, Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(if (state.working && !state.committed) "Cancel" else "Close", color = Muted) }
    })
}

@Composable fun SetupScreen(stateFlow: StateFlow<SetupState>, onPair: () -> Unit, onCheck: () -> Unit, onForget: () -> Unit, onReceipt: () -> Unit) {
    val state by stateFlow.collectAsStateWithLifecycle()
    var confirmForget by remember { mutableStateOf(false) }
    Frame(content = {
        Brand()
        Spacer(Modifier.height(32.dp))
        Heading(if (state.paired) "Your Mac, one share away." else "Screenshots. Straight to Codex.", state.message)
        if (state.busy) {
            Spacer(Modifier.height(20.dp))
            CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
        }
        Spacer(Modifier.height(26.dp))
        Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface, RoundedCornerShape(20.dp))
            .padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            listOf("Keep Codex Drop running on your Mac.", "Use the same Wi-Fi on both devices.", "Share 1–10 images → Codex Drop.").forEachIndexed { index, instruction ->
                Row {
                    Text("${index + 1}.", color = Aquamarine, lineHeight = 24.sp, modifier = Modifier.widthIn(min = 24.dp))
                    Spacer(Modifier.width(10.dp))
                    Text(instruction, lineHeight = 24.sp, color = Muted, modifier = Modifier.weight(1f))
                }
            }
        }
    }, buttons = {
        Button(if (state.paired) onCheck else onPair, Modifier.fillMaxWidth().heightIn(min = 54.dp), enabled = !state.busy) { Text(if (state.paired) "Check connection" else "Pair your Mac") }
        if (state.paired) {
            OutlinedButton(onPair, Modifier.fillMaxWidth().heightIn(min = 54.dp), enabled = !state.busy) { Text("Pair another Mac") }
            TextButton(onReceipt, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = !state.busy) { Text("Check last share") }
            TextButton({ confirmForget = true }, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = !state.busy) { Text("Forget pairing", color = Muted) }
        }
    })
    if (confirmForget) AlertDialog(onDismissRequest = { confirmForget = false }, title = { Text("Forget this Mac?") }, text = { Text("You’ll need to scan its pairing QR code before sharing again.") }, confirmButton = { TextButton({ confirmForget = false; onForget() }) { Text("Forget") } }, dismissButton = { TextButton({ confirmForget = false }) { Text("Cancel") } })
}
