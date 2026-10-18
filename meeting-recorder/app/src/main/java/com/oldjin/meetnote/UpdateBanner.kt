package com.oldjin.meetnote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** 새 버전이 있을 때 홈 상단에 보이는 카드. */
@Composable
fun UpdateBanner() {
    val ctx = LocalContext.current
    val info by Updater.available.collectAsState()
    val progress by Updater.progress.collectAsState()
    val i = info ?: return
    Card(
        Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(Modifier.weight(1f)) {
                    Text("새 버전이 있어요", fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onPrimaryContainer)
                    Text(
                        "현재 ${BuildConfig.VERSION_NAME} → 빌드 ${if (i.build > 0) i.build else i.sha}" +
                            if (i.size > 0) " · ${i.size / 1_000_000}MB" else "",
                        fontSize = 12.sp, color = MaterialTheme.colorScheme.onPrimaryContainer
                    )
                }
                Button(onClick = { Updater.downloadAndInstall(ctx, i) }, enabled = progress == null) {
                    Text(if (progress == null) "업데이트" else "받는 중")
                }
            }
            progress?.let { LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth()) }
            val msg by Updater.message.collectAsState()
            if (msg.startsWith("설치") || msg.startsWith("다운로드")) {
                Text(msg, fontSize = 12.sp, color = MaterialTheme.colorScheme.onPrimaryContainer)
            }
        }
    }
}

/** 실시간 자막에 필요한 모델이 없을 때 홈에 보이는 설치 카드. */
@Composable
fun ModelInstallCard() {
    val ctx = LocalContext.current
    val ver by LocalModels.version.collectAsState()
    if (Prefs.captionMode(ctx) != "device") return
    val needs = remember(ver) { !GoogleCaption.available(ctx) && !LocalModels.installed(ctx, LocalModels.KO_STREAM) }
    if (!needs) return
    Card(
        Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("무료 실시간 자막 준비", fontWeight = FontWeight.SemiBold)
            Text(
                "이 폰은 Google 기기 내 인식을 쓸 수 없어, API 없이 자막을 만들려면 한국어 인식 모델을 한 번 설치해야 해요.",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            ModelRow(LocalModels.KO_STREAM)
        }
    }
}

/** 모델 한 줄: 이름·설명·설치/삭제 버튼·진행률 */
@Composable
fun ModelRow(m: LocalModel) {
    val ctx = LocalContext.current
    val progress by LocalModels.progress.collectAsState()
    val messages by LocalModels.messages.collectAsState()
    val ver by LocalModels.version.collectAsState()
    val installed = remember(ver) { LocalModels.installed(ctx, m) }
    val p = progress[m.id]
    val msg = messages[m.id].orEmpty()
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f)) {
                Text(m.title + if (installed) "  ✓" else "", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text("${m.desc} · ${m.size}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            when {
                p != null -> Text("${(p * 100).toInt()}%", fontSize = 13.sp, color = MaterialTheme.colorScheme.primary)
                installed -> TextButton(onClick = { LocalModels.delete(ctx, m) }) { Text("삭제") }
                else -> Button(onClick = { LocalModels.install(ctx, m) }) { Text("설치") }
            }
        }
        if (p != null) {
            LinearProgressIndicator(progress = { p }, modifier = Modifier.fillMaxWidth())
            Text(msg, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else if (msg.startsWith("설치 실패")) Text(msg, fontSize = 12.sp, color = MaterialTheme.colorScheme.error)
    }
}
