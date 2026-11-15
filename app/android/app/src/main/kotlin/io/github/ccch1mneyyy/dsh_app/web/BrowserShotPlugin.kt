package io.github.ccch1mneyyy.dsh_app.web

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 网页截图: draws the app's own WebView into a bitmap and saves a JPEG where the engine can
 * read it.
 *
 * Flutter's RepaintBoundary cannot capture a platform view (the WebView is rendered by
 * Android, not by Flutter's layer tree), so the capture happens here: `WebView.draw()`
 * paints the visible viewport onto a software canvas. A hardware-accelerated WebView may
 * draw nothing that way; when the first attempt comes out blank it is retried once with a
 * software layer, then the layer type is put back.
 *
 * Writes to the shared 下载 folder (`下载/DSH-Go/screenshots`) rather than app-private
 * storage, because the agent runs in the same uid and has to read the file back. Old shots
 * are cleaned up after 7 days.
 */
class BrowserShotPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capture" -> capture(call, result)
            "tap" -> tap(call, result)
            else -> result.notImplemented()
        }
    }

    /**
     * A real touch on the page at (x, y) in view pixels. A scripted `element.click()` is not a
     * user gesture, so a page's file chooser never opens for it; a synthesized touch is one, and
     * `onShowFileChooser` then answers with the upload tool's file.
     */
    private fun tap(call: MethodCall, result: MethodChannel.Result) {
        val x = call.argument<Number>("x")?.toFloat()
        val y = call.argument<Number>("y")?.toFloat()
        val host = activity
        val web = host?.let { findWebView(it.window.decorView, null) }
        if (x == null || y == null || web == null) {
            result.success(mapOf<String, Any?>("error" to "browser_closed", "message" to "浏览器没打开，先 browser_open"))
            return
        }
        host.runOnUiThread {
            // Chrome only treats this as a tap when the view owns the focus and the down/up
            // are apart in time: two events dispatched in the same frame can be folded into
            // a scroll guard and dropped, which looks exactly like "the page ignored me".
            web.requestFocus()
            val downTime = SystemClock.uptimeMillis()
            val down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, x, y, 0).apply {
                source = android.view.InputDevice.SOURCE_TOUCHSCREEN
            }
            try {
                web.dispatchTouchEvent(down)
            } catch (_: Exception) {
            } finally {
                down.recycle()
            }
            web.postDelayed({
                val up = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y, 0).apply {
                    source = android.view.InputDevice.SOURCE_TOUCHSCREEN
                }
                try {
                    web.dispatchTouchEvent(up)
                } catch (_: Exception) {
                } finally {
                    up.recycle()
                }
            }, 90)
        }
        result.success(mapOf<String, Any?>("ok" to true))
    }

    private fun capture(call: MethodCall, result: MethodChannel.Result) {
        val host = activity
        val wanted = call.argument<String>("url")?.takeIf { it.isNotBlank() }
        val web = host?.let { findWebView(it.window.decorView, wanted) }
        if (web == null) {
            result.success(mapOf<String, Any?>("error" to "browser_closed"))
            return
        }
        if (web.width <= 0 || web.height <= 0) {
            // The browser is open but its (hidden) host has no size yet: say so, instead of
            // "browser_closed", which makes the model reopen a page that is already there.
            result.success(mapOf<String, Any?>(
                "error" to "browser_not_visible",
                "message" to "浏览器现在没有可截图的画面，先让用户切到浏览器页面再截图",
            ))
            return
        }
        val maxSide = (call.argument<Number>("maxSide")?.toInt() ?: 1600).coerceIn(320, 4096)
        val quality = (call.argument<Number>("quality")?.toInt() ?: 80).coerceIn(30, 95)
        val dir = File(call.argument<String>("dir")?.takeIf { it.isNotBlank() } ?: DEFAULT_DIR)
        val bitmap = try {
            draw(web, maxSide)
        } catch (error: Throwable) {
            result.success(mapOf<String, Any?>("error" to "capture_failed", "message" to "${error.message ?: error}"))
            return
        }
        if (bitmap == null) {
            result.success(mapOf<String, Any?>("error" to "capture_failed", "message" to "页面画不出图"))
            return
        }
        // Compression is the slow part; keep it off the platform thread.
        Thread {
            val saved = try {
                save(bitmap, dir, quality)
            } catch (error: Throwable) {
                null
            } finally {
                bitmap.recycle()
            }
            val answer = if (saved == null) {
                mapOf<String, Any?>("error" to "capture_failed", "message" to "截图保存失败")
            } else {
                mapOf<String, Any?>(
                    "path" to saved.file.absolutePath,
                    "width" to saved.width,
                    "height" to saved.height,
                    "bytes" to saved.file.length(),
                )
            }
            result.success(answer)
        }.start()
    }

    private class Shot(val file: File, val width: Int, val height: Int)

    /**
     * The WebView the browser page paints into, wherever it sits in the activity's view tree.
     *
     * The app can have more than one WebView (the embedded DSH Web UI has its own), so the
     * one whose address matches [wanted] wins; otherwise the biggest one does.
     */
    private fun findWebView(view: View?, wanted: String?): WebView? {
        val found = ArrayList<WebView>()
        collect(view, found)
        if (found.isEmpty()) return null
        if (wanted != null) {
            // Chrome adds/strips the trailing slash (`https://example.com` → `/`): an exact
            // string compare then misses the page that is right there and falls back blind.
            val target = normalizeUrl(wanted)
            found.firstOrNull { normalizeUrl(it.url ?: "") == target }?.let { return it }
        }
        return found.maxByOrNull { it.width.toLong() * it.height }
    }

    private fun normalizeUrl(url: String): String {
        var value = url.trim().substringBefore('#')
        while (value.length > 1 && value.endsWith("/")) value = value.dropLast(1)
        return value
    }

    private fun collect(view: View?, into: MutableList<WebView>) {
        if (view == null) return
        if (view is WebView) {
            into.add(view)
            return
        }
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) collect(view.getChildAt(index), into)
        }
    }

    private fun draw(web: WebView, maxSide: Int): Bitmap? {
        val width = web.width
        val height = web.height
        if (width <= 0 || height <= 0) return null
        val scale = minOf(1f, maxSide.toFloat() / maxOf(width, height))
        val targetWidth = (width * scale).toInt().coerceAtLeast(1)
        val targetHeight = (height * scale).toInt().coerceAtLeast(1)
        fun paint(): Bitmap {
            val bitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.scale(targetWidth / width.toFloat(), targetHeight / height.toFloat())
            canvas.translate(-web.scrollX.toFloat(), -web.scrollY.toFloat())
            web.draw(canvas)
            return bitmap
        }
        val hardware = paint()
        if (!looksBlank(hardware)) return hardware
        // Drawn into a software canvas a hardware-accelerated WebView can come out empty.
        hardware.recycle()
        val before = web.layerType
        return try {
            web.setLayerType(View.LAYER_TYPE_SOFTWARE, null)
            val software = paint()
            web.setLayerType(before, null)
            software
        } catch (error: Throwable) {
            runCatching { web.setLayerType(before, null) }
            throw error
        }
    }

    /** A capture that never painted is one colour; real pages are not. */
    private fun looksBlank(bitmap: Bitmap): Boolean {
        val thumb = Bitmap.createScaledBitmap(bitmap, 24, 24, false)
        val pixels = IntArray(24 * 24)
        thumb.getPixels(pixels, 0, 24, 0, 0, 24, 24)
        thumb.recycle()
        // JPEG draws white; a failed draw is fully transparent.
        var transparent = 0
        for (pixel in pixels) if (pixel ushr 24 == 0) transparent++
        return transparent >= pixels.size * 9 / 10
    }

    private fun save(bitmap: Bitmap, dir: File, quality: Int): Shot? {
        if (!dir.exists() && !dir.mkdirs()) return null
        prune(dir)
        val name = "shot-" + SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()) + ".jpg"
        var file = File(dir, name)
        var index = 1
        while (file.exists()) {
            file = File(dir, name.replace(".jpg", "-$index.jpg"))
            index++
        }
        var source = bitmap
        var q = quality
        var attempt = 0
        while (true) {
            FileOutputStream(file).use { out -> source.compress(Bitmap.CompressFormat.JPEG, q, out) }
            if (file.length() > 0 && file.length() <= MAX_BYTES || attempt >= 3) break
            if (q > 45) {
                q -= 10
            } else {
                attempt++
                val smaller = Bitmap.createScaledBitmap(source, (source.width * 3) / 4, (source.height * 3) / 4, true)
                if (smaller !== source) source.recycle()
                source = smaller
            }
        }
        val width = source.width
        val height = source.height
        if (source !== bitmap) source.recycle()
        return if (file.length() > 0) Shot(file, width, height) else null
    }

    /** Seven days of shots; the folder is in shared storage, so it does not grow forever. */
    private fun prune(dir: File) {
        val cutoff = System.currentTimeMillis() - PRUNE_MS
        dir.listFiles()?.forEach { file ->
            if (file.isFile && file.lastModified() < cutoff) runCatching { file.delete() }
        }
    }

    companion object {
        private const val CHANNEL = "dsh/browser-shot"
        private const val DEFAULT_DIR = "/sdcard/Download/DSH-Go/screenshots"
        private const val MAX_BYTES = 500 * 1024
        private const val PRUNE_MS = 7L * 24 * 60 * 60 * 1000
    }
}
