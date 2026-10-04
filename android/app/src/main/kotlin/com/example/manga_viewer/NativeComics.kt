package com.example.manga_viewer

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import com.github.junrar.Archive
import com.github.junrar.exception.UnsupportedRarV5Exception
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * PDF pages (Android's PdfRenderer) and RAR/CBR entries (junrar, RAR 4 and
 * older) for the Dart ComicBook. Everything runs on one background thread:
 * neither PdfRenderer nor junrar's Archive may be used concurrently, and the
 * last opened document is kept open for the next page.
 */
class NativeComics : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var pdfPath: String? = null
    private var pdfFd: ParcelFileDescriptor? = null
    private var pdf: PdfRenderer? = null

    private var rarPath: String? = null
    private var rar: Archive? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        worker.execute {
            try {
                val value: Any? = when (call.method) {
                    "pdfPageCount" -> openPdf(call.argument<String>("path")!!).pageCount
                    "pdfRender" -> renderPdf(
                        call.argument<String>("path")!!,
                        call.argument<Int>("index")!!,
                        call.argument<Int>("width")!!,
                    )
                    "rarList" -> openRar(call.argument<String>("path")!!).fileHeaders
                        .filter { !it.isDirectory }
                        .map { it.fileName.replace('\\', '/') }
                    "rarRead" -> readRar(call.argument<String>("path")!!, call.argument<String>("name")!!)
                    else -> {
                        main.post { result.notImplemented() }
                        return@execute
                    }
                }
                main.post { result.success(value) }
            } catch (e: UnsupportedRarV5Exception) {
                main.post { result.error("rar5", "RAR5 format is not supported", null) }
            } catch (e: Throwable) {
                main.post { result.error("comics", e.toString(), null) }
            }
        }
    }

    private fun openPdf(path: String): PdfRenderer {
        if (path != pdfPath) {
            pdf?.close()
            pdfFd?.close()
            pdf = null
            pdfPath = null
            val fd = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
            pdfFd = fd
            pdf = PdfRenderer(fd)
            pdfPath = path
        }
        return pdf!!
    }

    private fun renderPdf(path: String, index: Int, width: Int): ByteArray {
        val page = openPdf(path).openPage(index)
        try {
            val w = width.coerceIn(64, 2400)
            val h = (w.toLong() * page.height / page.width).toInt().coerceIn(64, 4800)
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.WHITE) // PDFs are drawn on transparent paper
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 92, out)
            bitmap.recycle()
            return out.toByteArray()
        } finally {
            page.close()
        }
    }

    private fun openRar(path: String): Archive {
        if (path != rarPath) {
            rar?.close()
            rar = null
            rarPath = null
            val archive = Archive(File(path))
            if (archive.isEncrypted) {
                archive.close()
                throw IllegalStateException("Encrypted RAR archives are not supported")
            }
            rar = archive
            rarPath = path
        }
        return rar!!
    }

    private fun readRar(path: String, name: String): ByteArray {
        val archive = openRar(path)
        val header = archive.fileHeaders.firstOrNull { it.fileName.replace('\\', '/') == name }
            ?: throw IllegalArgumentException("No entry $name")
        val out = ByteArrayOutputStream(header.fullUnpackSize.toInt().coerceAtLeast(32))
        archive.extractFile(header, out)
        return out.toByteArray()
    }
}
