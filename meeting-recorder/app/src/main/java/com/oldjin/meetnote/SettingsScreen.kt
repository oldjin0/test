package com.oldjin.meetnote

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onBack: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var key by remember { mutableStateOf("") }
    var model by remember { mutableStateOf(Prefs.model(ctx)) }
    var lang by remember { mutableStateOf(Prefs.lang(ctx)) }
    var hasKey by remember { mutableStateOf(!Prefs.apiKey(ctx).isNullOrBlank()) }
    var checking by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text("설정", fontWeight = FontWeight.Bold) },
                navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "뒤로") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)
            )
        }
    ) { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(horizontal = 16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text("Google Gemini API 키", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            Text(
                if (hasKey) "등록됨 (기기 보안 저장소에 암호화되어 저장)" else "아직 등록되지 않았습니다",
                color = if (hasKey) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error, fontSize = 13.sp
            )
            OutlinedTextField(
                value = key, onValueChange = { key = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                label = { Text(if (hasKey) "새 키로 교체" else "API 키 붙여넣기") },
                visualTransformation = PasswordVisualTransformation()
            )
            OutlinedButton(
                onClick = { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://aistudio.google.com/apikey"))) },
                modifier = Modifier.fillMaxWidth()
            ) { Text("Google AI Studio에서 키 발급받기") }
            OutlinedTextField(
                value = model, onValueChange = { model = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                label = { Text("모델 (비워두면 자동 선택)") },
                supportingText = { Text("사용 가능한 최신 Gemini flash 모델을 자동으로 고릅니다") }
            )
            OutlinedTextField(
                value = lang, onValueChange = { lang = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                label = { Text("실시간 인식 언어 (예: ko-KR, en-US)") }
            )
            Button(
                enabled = !checking && (key.isNotBlank() || model != Prefs.model(ctx) || lang != Prefs.lang(ctx)),
                modifier = Modifier.fillMaxWidth(),
                onClick = {
                    scope.launch {
                        checking = true
                        val candidate = key.trim().ifBlank { Prefs.apiKey(ctx).orEmpty() }
                        var found = ""
                        val err = withContext(Dispatchers.IO) {
                            try { GeminiClient(ctx, candidate, model.trim()).also { it.validateKey(); it.ensureModels(force = true) }.let { c -> found = "텍스트: " + c.textModel() + " / 실시간: " + (c.liveModel() ?: "없음(구간 변환)") }; null } catch (e: Exception) { e.message ?: "오류" }
                        }
                        checking = false
                        if (err == null) {
                            if (key.isNotBlank()) Prefs.setApiKey(ctx, key)
                            Prefs.setModel(ctx, model); Prefs.setLang(ctx, lang)
                            key = ""; hasKey = true
                            Toast.makeText(ctx, "저장되었습니다\n$found", Toast.LENGTH_LONG).show()
                        } else {
                            Toast.makeText(ctx, "키 확인 실패: $err", Toast.LENGTH_LONG).show()
                        }
                    }
                }
            ) { Text(if (checking) "확인 중…" else "확인 후 저장") }

            Spacer(Modifier.height(8.dp))
            Text("API 사용량 줄이기", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            Text(
                "무료 한도가 부족하면 아래를 끄세요. 모두 끄면 녹음만 하고, 필요할 때 녹음마다 변환을 눌러 1~2회만 사용합니다.",
                fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            var capMode by remember { mutableStateOf(Prefs.captionMode(ctx)) }
            var optAuto by remember { mutableStateOf(Prefs.autoAnalyze(ctx)) }
            var optSummary by remember { mutableStateOf(Prefs.summaryOn(ctx)) }
            @Composable
            fun OptRow(title: String, desc: String, v: Boolean, key: String, set: (Boolean) -> Unit) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(title, fontSize = 15.sp)
                        Text(desc, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(checked = v, onCheckedChange = { set(it); Prefs.setOpt(ctx, key, it) })
                }
            }
            Text("실시간 자막 방식", fontSize = 15.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("live" to "Gemini Live (API 사용)", "device" to "기기 내 (무료)", "off" to "끄기").forEach { (k, label) ->
                    androidx.compose.material3.FilterChip(
                        selected = capMode == k, onClick = { capMode = k; Prefs.setCaptionMode(ctx, k) }, label = { Text(label, fontSize = 12.sp) }
                    )
                }
            }
            Text(
                when (capMode) {
                    "live" -> "정확하고 빠르지만 API 한도를 씁니다."
                    "device" -> "API·한도·네트워크 없이 기기에서 인식합니다. 정확도는 낮을 수 있고 화자 구분은 종료 후 분석에서 합니다. 한국어 모델(약 80MB)을 한 번 설치해야 합니다."
                    else -> "녹음 중 자막을 만들지 않습니다. 녹음이 끝난 뒤에 변환할 수 있어요."
                },
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (capMode == "device") {
                val prog by ModelInstaller.progress.collectAsState()
                val msg by ModelInstaller.message.collectAsState()
                val installed = ModelInstaller.installed(ctx) || msg == "설치 완료"
                OutlinedButton(
                    onClick = { ModelInstaller.install(ctx) }, enabled = prog == null && !installed, modifier = Modifier.fillMaxWidth()
                ) { Text(if (installed) "기기 내 인식 모델 설치됨" else if (prog != null) "$msg ${(prog!! * 100).toInt()}%" else "한국어 모델 설치 (약 80MB)") }
                if (!installed && msg.startsWith("설치 실패")) Text(msg, fontSize = 12.sp, color = MaterialTheme.colorScheme.error)
            }
            OptRow("종료 후 AI 자동 분석", "끄면 기기 내 간이 요약만 만들고, 필요한 녹음만 상세 화면에서 AI 분석 (요청 1~2회)", optAuto, "opt_auto2") { optAuto = it }
            OptRow("AI 요약", "AI 분석 때 요약도 생성 (요청 1회). 끄면 기기 내 요약을 사용", optSummary, "opt_summary") { optSummary = it }

            Spacer(Modifier.height(8.dp))
            Text("앱 업데이트", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            val checking by Updater.checking.collectAsState()
            val upMsg by Updater.message.collectAsState()
            val upInfo by Updater.available.collectAsState()
            Text(
                "현재 버전 ${BuildConfig.VERSION_NAME} (${BuildConfig.GIT_SHA})" + if (upMsg.isNotBlank()) "\n$upMsg" else "",
                fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            OutlinedButton(onClick = { Updater.check(ctx) }, enabled = !checking, modifier = Modifier.fillMaxWidth()) {
                Text(if (checking) "확인 중…" else "업데이트 확인")
            }
            upInfo?.let { i ->
                Button(onClick = { Updater.downloadAndInstall(ctx, i) }, modifier = Modifier.fillMaxWidth()) { Text("지금 업데이트") }
            }

            Spacer(Modifier.height(8.dp))
            Text("안정적인 백그라운드 녹음", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            Text(
                "일부 제조사(삼성·샤오미 등)는 백그라운드 앱을 강제 종료합니다. 장시간 회의 전에 배터리 최적화에서 MeetNote를 제외해 주세요.",
                fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            OutlinedButton(
                onClick = { ctx.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) },
                modifier = Modifier.fillMaxWidth()
            ) { Text("배터리 최적화 설정 열기") }

            Spacer(Modifier.height(8.dp))
            Text("개인정보 안내", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            Text(
                "• 녹음된 음성은 텍스트 변환과 요약을 위해 Google Gemini API로 전송됩니다. 무료 사용량(키 유형)에 따라 Google이 서비스 개선에 입력 데이터를 사용할 수 있으니 민감한 회의에는 유료 키를 권장합니다.\n" +
                    "• 녹음 전에 참석자 모두에게 동의를 받아 주세요.\n" +
                    "• 결과 파일은 앱 내부와 다운로드/MeetNote 폴더에 저장됩니다.",
                fontSize = 13.sp, lineHeight = 19.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(Modifier.height(24.dp))
        }
    }
}
