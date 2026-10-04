package com.example.manga_viewer

import android.content.ContentValues
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "manga_viewer/comics")
            .setMethodCallHandler(NativeComics())
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "manga_viewer/app")
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
