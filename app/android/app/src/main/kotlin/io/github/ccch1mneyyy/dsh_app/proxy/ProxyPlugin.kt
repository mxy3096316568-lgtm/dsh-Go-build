package io.github.ccch1mneyyy.dsh_app.proxy

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import java.io.File
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import org.json.JSONObject
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * 内置代理: mihomo as a local mixed-port proxy, for this app only.
 *
 * The kernel ships as `libmihomo.so` in `nativeLibraryDir` (the only place Android lets an app
 * execute from: `extractNativeLibs=true` in the manifest, `useLegacyPackaging` in Gradle), and
 * listens on 127.0.0.1. WebView is pointed at it through androidx.webkit's ProxyController, and
 * the app's own HTTP clients set `findProxy`. Nothing outside the app is routed, so no VPN and no
 * system-wide change: closing the switch puts everything back.
 *
 * The subscription is fetched and normalised on the Dart side (that is where the YAML parser
 * lives) and written here as a Clash config.
 */
class ProxyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var app: Context? = null

    // Starting the kernel waits for its port (up to 20 s). On the platform thread that is an
    // ANR — the whole app freezes when the tap finally succeeds. One worker and one explicit
    // busy flag keep both a second tap and the UI out of that wait.
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile
    private var busy = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        app = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dsh/proxy").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        app = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = app ?: return result.success(null)
        when (call.method) {
            "status" -> result.success(status(context))
            "writeConfig" -> {
                val content = call.argument<String>("content")
                if (content.isNullOrBlank()) {
                    result.success(mapOf("error" to "empty_config"))
                } else {
                    result.success(writeConfig(context, content))
                }
            }
            "readConfig" -> result.success(readConfig(context))
            "start" -> {
                val port = call.argument<Number>("port")?.toInt() ?: DEFAULT_PORT
                runOffMain(context, result) { start(context, port) }
            }
            "stop" -> runOffMain(context, result) { stop(context) }
            "test" -> runOffMain(context, result) { test(context) }
            "log" -> runOffMain(context, result) { mapOf("lines" to lastLines(logFile(context), 40)) }
            else -> result.notImplemented()
        }
    }

    /** Runs [work] on the worker; the reply goes back on the platform thread. */
    private fun runOffMain(context: Context, result: MethodChannel.Result, work: () -> Map<String, Any?>) {
        if (busy) {
            result.success(status(context) + mapOf("error" to "busy", "message" to "上一次启动/停止还没结束，稍等几秒"))
            return
        }
        busy = true
        worker.execute {
            val out = try {
                work()
            } catch (error: Exception) {
                status(context) + mapOf("error" to "start_failed", "message" to (error.message ?: error.toString()))
            } finally {
                busy = false
            }
            try {
                writeStatusFile(context)
            } catch (_: Exception) {
            }
            main.post { result.success(out) }
        }
    }

    private fun status(context: Context): Map<String, Any?> = mapOf(
        "running" to isRunning(),
        "port" to port,
        "webViewProxy" to webViewProxy,
        "kernel" to binary(context).exists(),
        "config" to configFile(context).exists(),
        "error" to lastError,
        "lastTest" to lastTest,
    )

    /** The config on disk, so the Dart side can re-sanitise one written by an older version. */
    private fun readConfig(context: Context): Map<String, Any?> = try {
        val file = configFile(context)
        if (!file.exists()) {
            mapOf("error" to "no_config")
        } else {
            mapOf("content" to file.readText(), "path" to file.absolutePath, "bytes" to file.length())
        }
    } catch (error: Exception) {
        mapOf("error" to "read_failed", "message" to "${error.message ?: error}")
    }

    private fun writeConfig(context: Context, content: String): Map<String, Any?> = try {
        val dir = dataDir(context)
        val file = configFile(context)
        file.writeText(content)
        mapOf("ok" to true, "path" to file.absolutePath, "bytes" to file.length(), "dir" to dir.absolutePath)
    } catch (error: Exception) {
        mapOf("error" to "write_failed", "message" to "${error.message ?: error}")
    }

    private fun start(context: Context, requestedPort: Int): Map<String, Any?> {
        lastError = null
        if (isRunning()) return status(context)
        val binary = binary(context)
        if (!binary.exists()) {
            lastError = "内核没有打包进来"
            return status(context) + mapOf("error" to "kernel_missing")
        }
        val config = configFile(context)
        if (!config.exists() || config.length() == 0L) {
            lastError = "还没有订阅配置"
            return status(context) + mapOf("error" to "no_config")
        }
        port = requestedPort.coerceIn(1024, 65535)
        // A force-closed app leaves its kernel running (it is a separate process). That kernel
        // then owns the port and every later start reports "port in use" for our own child.
        killStaleKernel(context, port)
        if (!portFree(port)) {
            lastError = "端口 $port 已被其他应用占用，请换端口"
            return status(context) + mapOf("error" to "port_in_use", "port" to port,
                "suggest" to suggestPort(port), "message" to lastError)
        }
        return try {
            val log = logFile(context)
            val started = MihomoProcess.start(binary, dataDir(context), config, log)
            process = started
            writePid(context, pidOf(started))
            if (!waitForPort(port, 20000)) {
                started.destroy()
                process = null
                // The port may have been taken while the kernel was starting (another proxy
                // app coming up, a leftover process, a second DSH Go): say so instead of
                // blaming the subscription.
                if (portAccepts(port)) {
                    lastError = "端口 $port 已被其他应用占用，请换端口"
                    return status(context) + mapOf("error" to "port_in_use", "port" to port,
                        "suggest" to suggestPort(port), "message" to lastError)
                }
                lastError = "内核启动超时（20 秒端口没起来）"
                return status(context) + mapOf("error" to "start_timeout", "log" to lastLines(log, 20))
            }
            setWebViewProxy(context, true)
            // Prove the kernel is not just listening but actually carrying traffic: "port
            // open, nothing blocked" was reported as a working proxy while every request
            // silently fell back to direct (ProxyConfig's addDirect()).
            worker.execute { probe(context) }
            status(context)
        } catch (error: Exception) {
            process = null
            lastError = error.message ?: error.toString()
            status(context) + mapOf("error" to "start_failed", "message" to lastError)
        }
    }

    private fun stop(context: Context): Map<String, Any?> {
        setWebViewProxy(context, false)
        process?.let { running ->
            running.destroy()
            try {
                running.waitFor()
            } catch (_: InterruptedException) {
                running.destroyForcibly()
            }
        }
        process = null
        File(dataDir(context), "mihomo.pid").delete()
        // Killing is asynchronous: the page shows 「已关闭」 only once the port can be bound
        // again, otherwise the next start would report the old kernel as a port conflict.
        waitPortFree(port, 3000)
        return status(context)
    }

    /** Points WebView at the local port (all WebViews of this app; nothing else). */
    private fun setWebViewProxy(context: Context, enabled: Boolean) {
        val executor = Executor { command -> command.run() }
        try {
            if (enabled) {
                // No `addDirect()`: the old fallback turned every request that the dead
                // kernel did not answer into a direct one, so "proxy on" looked like it
                // worked while blocked sites failed. Without it a broken proxy fails
                // loudly — which is the only state worth reporting.
                val config = ProxyConfig.Builder()
                    .addProxyRule("127.0.0.1:$port")
                    .build()
                ProxyController.getInstance().setProxyOverride(config, executor) { webViewProxy = true }
            } else {
                ProxyController.getInstance().clearProxyOverride(executor) { webViewProxy = false }
            }
        } catch (error: Exception) {
            // WebView without ProxyController support (very old system WebView): the kernel still
            // runs and the app's own downloads use it; pages just stay direct.
            webViewProxy = false
            lastError = "WebView 不支持代理设置：${error.message ?: error}"
        }
    }

    /**
     * A real HTTPS request through the local port. A kernel that listens proves nothing:
     * ProxyConfig falls back to `addDirect()`, so a dead node looks exactly like a working
     * proxy until a blocked site is opened. Two known-blocked sites answer the question
     * the person is actually asking.
     */
    private fun test(context: Context): Map<String, Any?> {
        if (!isRunning()) {
            return status(context) + mapOf(
                "error" to "not_running",
                "message" to "内核没在跑，先把开关打开再测",
            )
        }
        val results = listOf("www.google.com", "en.wikipedia.org").map { probeHost(it, 8000) }
        val ok = results.all { it["ok"] == true }
        lastTest = mapOf("at" to System.currentTimeMillis(), "ok" to ok, "results" to results)
        return status(context) + mapOf("ok" to ok, "results" to results)
    }

    private fun probeHost(host: String, timeoutMs: Int): Map<String, Any?> {
        val started = System.currentTimeMillis()
        var connection: HttpURLConnection? = null
        return try {
            connection = URL("https://$host/").openConnection(
                Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", port)),
            ) as HttpURLConnection
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android) DSH-Go")
            val code = connection.responseCode
            mapOf(
                "host" to host,
                "ok" to (code in 200..399),
                "status" to code,
                "ms" to (System.currentTimeMillis() - started),
            )
        } catch (error: Exception) {
            mapOf(
                "host" to host,
                "ok" to false,
                "error" to (error.message ?: error.javaClass.simpleName),
                "ms" to (System.currentTimeMillis() - started),
            )
        } finally {
            try {
                connection?.disconnect()
            } catch (_: Exception) {
            }
        }
    }

    /** Background probe after a successful start: never blocks the caller, updates [lastTest]. */
    private fun probe(context: Context) {
        try {
            test(context)
        } catch (_: Exception) {
        }
    }

    /**
     * Same facts as the page, as a file the terminal side can read
     * (`/sdcard/Download/DSH-Go/proxy-status.json`). Without it every proxy question needs
     * a screenshot of the settings page.
     */
    private fun writeStatusFile(context: Context) {
        try {
            val dir = File("/sdcard/Download/DSH-Go")
            if (!dir.isDirectory && !dir.mkdirs()) return
            val report = JSONObject()
            report.put("at", System.currentTimeMillis())
            report.put("running", isRunning())
            report.put("port", port)
            report.put("webViewProxy", webViewProxy)
            report.put("kernel", binary(context).exists())
            report.put("config", configFile(context).exists())
            report.put("error", lastError ?: JSONObject.NULL)
            report.put("lastTest", lastTest?.let { JSONObject(it) } ?: JSONObject.NULL)
            report.put("log", org.json.JSONArray(lastLines(logFile(context), 25)))
            File(dir, "proxy-status.json").writeText(report.toString(2))
        } catch (_: Exception) {
        }
    }

    private fun pidOf(process: Process): Long = try {
        (Process::class.java.getMethod("pid").invoke(process) as? Long) ?: -1L
    } catch (_: Exception) {
        -1L
    }

    private fun writePid(context: Context, pid: Long) {
        if (pid <= 0) return
        try {
            File(dataDir(context), "mihomo.pid").writeText(pid.toString())
        } catch (_: Exception) {
        }
    }

    /** Best effort: kill the kernel a previous app process left behind, if it still runs. */
    private fun killStaleKernel(context: Context, port: Int) {
        val pidFile = File(dataDir(context), "mihomo.pid")
        val pid = try {
            if (pidFile.exists()) pidFile.readText().trim().toIntOrNull() ?: -1 else -1
        } catch (_: Exception) {
            -1
        }
        if (pid <= 0) return
        val cmdline = try {
            File("/proc/$pid/cmdline").readText().replace('\u0000', ' ')
        } catch (_: Exception) {
            ""
        }
        if (cmdline.contains("libmihomo")) {
            try {
                android.os.Process.sendSignal(pid, android.os.Process.SIGNAL_KILL)
            } catch (_: Exception) {
            }
            waitPortFree(port, 2000)
        }
        pidFile.delete()
    }

    /** The first bindable port after [from], so "change the port" can name one. */
    private fun suggestPort(from: Int): Int {
        for (candidate in from + 1 until minOf(from + 32, 65536)) if (portFree(candidate)) return candidate
        return from + 1
    }

    /** Something already answers here: another proxy app, or a leftover kernel. */
    private fun portAccepts(port: Int): Boolean = try {
        Socket().use { socket ->
            socket.connect(InetSocketAddress("127.0.0.1", port), 250)
            true
        }
    } catch (_: Exception) {
        false
    }

    /**
     * Nothing is listening here. A real bind says more than a connect probe: it also catches a
     * port held by a socket that is not (yet) accepting. `reuseAddress` keeps a socket in
     * TIME_WAIT from a previous run from looking like a conflict.
     */
    private fun portFree(port: Int): Boolean = try {
        ServerSocket().use { server ->
            server.reuseAddress = true
            server.bind(InetSocketAddress("127.0.0.1", port), 1)
        }
        true
    } catch (_: Exception) {
        false
    }

    private fun waitPortFree(port: Int, timeoutMs: Int): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (portFree(port)) return true
            Thread.sleep(100)
        }
        return portFree(port)
    }

    private fun waitForPort(port: Int, timeoutMs: Int): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (process?.isAlive != true) return false
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress("127.0.0.1", port), 250)
                    return true
                }
            } catch (_: Exception) {
                Thread.sleep(150)
            }
        }
        return false
    }

    private fun dataDir(context: Context): File = File(context.filesDir, "mihomo").apply { mkdirs() }

    private fun configFile(context: Context) = File(dataDir(context), "config.yaml")

    private fun logFile(context: Context) = File(dataDir(context), "mihomo.log")

    /** The kernel itself, where the installer unpacked it (executable there). */
    private fun binary(context: Context) = File(context.applicationInfo.nativeLibraryDir, "libmihomo.so")

    /** The tail only: the kernel appends to this file forever, and reading it whole can stall. */
    private fun lastLines(file: File, count: Int): List<String> = try {
        if (!file.exists()) {
            emptyList()
        } else {
            RandomAccessFile(file, "r").use { handle ->
                val length = handle.length()
                val start = maxOf(0L, length - 256L * 1024L)
                handle.seek(start)
                val bytes = ByteArray((length - start).toInt())
                handle.readFully(bytes)
                String(bytes, Charsets.UTF_8).lineSequence().filter { it.isNotBlank() }.toList().takeLast(count)
            }
        }
    } catch (_: Exception) {
        emptyList()
    }

    companion object {
        private const val DEFAULT_PORT = 7890

        @Volatile
        private var process: Process? = null

        @Volatile
        private var port = DEFAULT_PORT

        @Volatile
        private var webViewProxy = false

        @Volatile
        private var lastError: String? = null

        @Volatile
        private var lastTest: Map<String, Any?>? = null

        private fun isRunning(): Boolean = process?.isAlive == true
    }
}
