package com.oldjin.meetnote

import android.Manifest
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MeetNoteTheme {
                Surface(Modifier.fillMaxSize().systemBarsPadding(), color = MaterialTheme.colorScheme.background) { App() }
            }
        }
    }
}

sealed interface Screen {
    data object Home : Screen
    data object Recording : Screen
    data object Settings : Screen
    data class Detail(val id: String) : Screen
}

private fun startRecording(ctx: Context) {
    Playback.stop()
    Live.state.value = LiveState(phase = Phase.Recording, status = "준비 중…")
    ContextCompat.startForegroundService(ctx, Intent(ctx, RecordingService::class.java).setAction(RecordingService.ACTION_START))
}

@Composable
fun App() {
    val ctx = LocalContext.current
    val live by Live.state.collectAsState()
    var screen by remember { mutableStateOf<Screen>(if (Live.busy) Screen.Recording else Screen.Home) }
    var version by remember { mutableIntStateOf(0) }

    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { res ->
        if (res[Manifest.permission.RECORD_AUDIO] == true) {
            startRecording(ctx)
            screen = Screen.Recording
        } else {
            Toast.makeText(ctx, "마이크 권한이 필요합니다", Toast.LENGTH_LONG).show()
        }
    }

    BackHandler(enabled = screen != Screen.Home) { screen = Screen.Home }

    when (val s = screen) {
        Screen.Home -> HomeScreen(
            live = live,
            version = version,
            onRecord = {
                if (Prefs.apiKey(ctx).isNullOrBlank()) {
                    Toast.makeText(ctx, "API 키 없이 녹음합니다. 텍스트 변환·요약은 나중에 할 수 있어요", Toast.LENGTH_LONG).show()
                }
                val perms = buildList {
                    add(Manifest.permission.RECORD_AUDIO)
                    if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
                }
                permLauncher.launch(perms.toTypedArray())
            },
            onOpenLive = { screen = Screen.Recording },
            onOpen = { screen = Screen.Detail(it) },
            onSettings = { screen = Screen.Settings },
        )
        Screen.Recording -> RecordingScreen(
            live = live,
            onBack = { screen = Screen.Home },
            onStop = { ctx.startService(Intent(ctx, RecordingService::class.java).setAction(RecordingService.ACTION_STOP)) },
            onResult = {
                val id = live.sessionId
                Live.state.value = LiveState()
                version++
                screen = if (id != null) Screen.Detail(id) else Screen.Home
            },
        )
        Screen.Settings -> SettingsScreen(onBack = { screen = Screen.Home })
        is Screen.Detail -> DetailScreen(id = s.id, onBack = { version++; screen = Screen.Home })
    }
}
