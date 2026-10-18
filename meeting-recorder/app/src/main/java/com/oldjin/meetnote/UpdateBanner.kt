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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
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
        }
    }
}

/** 기기 내 자막 모델이 없을 때 홈에 보이는 설치 카드. */
@Composable
fun ModelInstallCard() {
    val ctx = LocalContext.current
    val prog by ModelInstaller.progress.collectAsState()
    val msg by ModelInstaller.message.collectAsState()
    if (Prefs.captionMode(ctx) != "device" || ModelInstaller.installed(ctx) || msg == "설치 완료") return
    Card(
        Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("무료 실시간 자막 준비", fontWeight = FontWeight.SemiBold)
            Text(
                "API 없이 기기에서 자막을 만들려면 한국어 인식 모델(약 80MB)을 한 번 설치해야 해요. Wi-Fi에서 받는 걸 권장해요.",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (msg.startsWith("설치 실패")) Text(msg, fontSize = 12.sp, color = MaterialTheme.colorScheme.error)
            Button(onClick = { ModelInstaller.install(ctx) }, enabled = prog == null, modifier = Modifier.fillMaxWidth()) {
                Text(if (prog == null) "모델 설치" else "$msg ${((prog ?: 0f) * 100).toInt()}%")
            }
            prog?.let { LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth()) }
        }
    }
}
