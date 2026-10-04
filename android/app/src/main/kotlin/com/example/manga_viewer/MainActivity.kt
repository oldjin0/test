package com.example.manga_viewer

import android.content.ContentValues
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.view.KeyEvent
import android.view.WindowManager
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    private var appChannel: MethodChannel? = null

    /// While a reader is open, page buttons (e-readers' hardware buttons,
    /// keyboards, remotes) turn pages wherever the focus is; with the option
    /// on, the volume buttons do too instead of changing the volume.
    private var readerKeys = false
    private var volumeKeys = false

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (readerKeys) {
            val turn = when (event.keyCode) {
                KeyEvent.KEYCODE_PAGE_DOWN, KeyEvent.KEYCODE_MEDIA_NEXT -> "next"
                KeyEvent.KEYCODE_PAGE_UP, KeyEvent.KEYCODE_MEDIA_PREVIOUS -> "prev"
                KeyEvent.KEYCODE_VOLUME_DOWN -> if (volumeKeys) "next" else null
                KeyEvent.KEYCODE_VOLUME_UP -> if (volumeKeys) "prev" else null
                else -> null
            }
            if (turn != null) {
                if (event.action == KeyEvent.ACTION_DOWN) appChannel?.invokeMethod("key", turn)
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "manga_viewer/comics")
            .setMethodCallHandler(NativeComics())
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "manga_viewer/app")
        appChannel = channel
        channel
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "versionInfo" -> {
                            @Suppress("DEPRECATION")
                            val info = packageManager.getPackageInfo(packageName, 0)
                            result.success(
                                mapOf(
                                    "versionCode" to PackageInfoCompat.getLongVersionCode(info),
                                    "versionName" to (info.versionName ?: ""),
                                    "abis" to Build.SUPPORTED_ABIS.toList(),
                                )
                            )
                        }
                        // Android 8+: the user must allow this app to install updates once.
                        "canInstall" -> result.success(
                            Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                                packageManager.canRequestPackageInstalls()
                        )
                        "openInstallSettings" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:$packageName"),
                                    )
                                )
                            }
                            result.success(null)
                        }
                        "install" -> {
                            val file = File(call.argument<String>("path")!!)
                            val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                            val intent = Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_ACTIVITY_NEW_TASK
                                )
                            startActivity(intent)
                            result.success(true)
                        }
                        // Copies a file into Pictures/MangaViewer or Download/MangaViewer,
                        // where the gallery and file managers see it. Off the UI thread:
                        // an exported comic can be hundreds of MB.
                        "publish" -> {
                            val src = File(call.argument<String>("path")!!)
                            val name = call.argument<String>("name")!!
                            val mime = call.argument<String>("mime")!!
                            val pictures = call.argument<String>("collection") == "pictures"
                            Thread {
                                try {
                                    val where = publish(src, name, mime, pictures)
                                    runOnUiThread { result.success(where) }
                                } catch (e: Exception) {
                                    runOnUiThread { result.error("publish", e.message, null) }
                                }
                            }.start()
                        }
                        "keepScreenOn" -> {
                            if (call.argument<Boolean>("on") == true) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                            result.success(null)
                        }
                        "readerKeys" -> {
                            readerKeys = call.argument<Boolean>("on") == true
                            volumeKeys = readerKeys && call.argument<Boolean>("volume") == true
                            result.success(null)
                        }
                        "battery" -> {
                            val bm = getSystemService(BATTERY_SERVICE) as BatteryManager
                            result.success(bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
                        }
                        // Device tests: a hardware key press through the real dispatch path.
                        "pressKey" -> {
                            val code = call.argument<Int>("code")!!
                            dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
                            dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("app", e.message, null)
                }
            }
    }

    private fun publish(src: File, name: String, mime: String, pictures: Boolean): String {
        val base = if (pictures) Environment.DIRECTORY_PICTURES else Environment.DIRECTORY_DOWNLOADS
        val folder = "$base/MangaViewer"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, folder)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val collection = if (pictures) {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Downloads.EXTERNAL_CONTENT_URI
            }
            val uri = contentResolver.insert(collection, values)
                ?: throw IOException("MediaStore insert failed")
            contentResolver.openOutputStream(uri).use { out ->
                if (out == null) throw IOException("Cannot write $name")
                src.inputStream().use { it.copyTo(out) }
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return "$folder/$name"
        }
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(base), "MangaViewer")
        dir.mkdirs()
        val dst = File(dir, name)
        src.copyTo(dst, overwrite = true)
        MediaScannerConnection.scanFile(this, arrayOf(dst.path), arrayOf(mime), null)
        return dst.path
    }
}
