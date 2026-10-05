package me.whynbnb.ordo

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import rikka.shizuku.Shizuku
import java.io.BufferedReader
import java.io.InputStream
import java.io.InputStreamReader
import java.lang.reflect.Method
import java.security.SecureRandom
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * 高权限模式管理：Root / Shizuku /（后续）ADB。
 *
 * 三种模式共用同一个以 shell 或 root 身份运行的辅助进程 `ordo-privd`：
 * 把随 APK 打包的、对应 ABI 的二进制部署到 `/data/local/tmp`，启动后它会监听
 * 本地回环端口并把端口与令牌回传给 Dart，Rust 侧据此连接并转发文件操作。
 */
object PrivilegeManager {
    private const val HELPER_PATH = "/data/local/tmp/ordo-privd"
    private const val TAG = "ORDO_PRIVD "
    private const val REQUEST_CODE = 0x4f52

    private var session: Session? = null
    private var permissionFuture: CompletableFuture<Boolean>? = null
    private var suProcess: Process? = null
    private var shizukuProcess: Process? = null

    data class Session(val mode: String, val port: Int, val token: String)

    private val permissionListener =
        Shizuku.OnRequestPermissionResultListener { _, grantResult ->
            permissionFuture?.complete(grantResult == PackageManager.PERMISSION_GRANTED)
        }

    init {
        runCatching { Shizuku.addRequestPermissionResultListener(permissionListener) }
    }

    // ---------------------------------------------------------------------
    // 状态探测
    // ---------------------------------------------------------------------

    fun detect(context: Context): Map<String, Any> {
        val shizukuBinder = awaitBinder()
        val shizukuPermission = if (shizukuBinder) shizukuPermission() else -1
        return mapOf(
            "root" to rootAvailable(),
            "shizuku" to shizukuBinder,
            "shizukuPermission" to shizukuPermission,
            "adb" to AdbManager.available(context),
            "hostIp" to (AdbManager.hostIp(context) ?: ""),
            "active" to (session != null),
            "mode" to (session?.mode ?: "off"),
        )
    }

    /**
     * Shizuku 的 Binder 由其 ContentProvider 异步送达，冷启动时立即查询可能为 false。
     * 这里使用 sticky 监听等待一小段时间，避免误判为「未运行」。
     */
    fun awaitBinder(timeoutMs: Long = 1500): Boolean {
        if (runCatching { Shizuku.pingBinder() }.getOrDefault(false)) return true
        val latch = CountDownLatch(1)
        val listener = Shizuku.OnBinderReceivedListener { latch.countDown() }
        runCatching { Shizuku.addBinderReceivedListenerSticky(listener) }
        try {
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        } finally {
            runCatching { Shizuku.removeBinderReceivedListener(listener) }
        }
        return runCatching { Shizuku.pingBinder() }.getOrDefault(false)
    }

    fun rootAvailable(): Boolean {
        return runCatching {
            val process = ProcessBuilder("su", "-c", "id").redirectErrorStream(true).start()
            if (!waitFor(process, 4000)) {
                process.destroy()
                return@runCatching false
            }
            val output = process.inputStream.readBytes().decodeToString()
            process.exitValue() == 0 && output.contains("uid=0")
        }.getOrDefault(false)
    }

    fun shizukuAvailable(): Boolean = awaitBinder()

    fun shizukuPermission(): Int =
        runCatching { Shizuku.checkSelfPermission() }
            .getOrDefault(PackageManager.PERMISSION_DENIED)

    /** 请求 Shizuku 授权，返回是否已授权。 */
    fun requestShizukuPermission(): Boolean {
        if (!awaitBinder()) return false
        if (runCatching { Shizuku.isPreV11() }.getOrDefault(false)) return false
        if (shizukuPermission() == PackageManager.PERMISSION_GRANTED) return true
        // 用户曾选择「拒绝且不再询问」。
        if (runCatching { Shizuku.shouldShowRequestPermissionRationale() }.getOrDefault(false)) {
            return false
        }
        val future = CompletableFuture<Boolean>()
        permissionFuture = future
        // Shizuku 会拉起管理器的授权界面，放到主线程发起更稳妥。
        Handler(Looper.getMainLooper()).post {
            runCatching { Shizuku.requestPermission(REQUEST_CODE) }
                .onFailure { future.complete(false) }
        }
        return try {
            future.get(60, TimeUnit.SECONDS)
        } catch (_: Exception) {
            false
        } finally {
            permissionFuture = null
        }
    }

    // ---------------------------------------------------------------------
    // 启动 / 停止
    // ---------------------------------------------------------------------

    fun start(context: Context, mode: String): Session {
        stop()
        val token = randomToken()
        val port = when (mode) {
            "root" -> startWithSu(context, token)
            "shizuku" -> startWithShizuku(context, token)
            "adb" -> AdbManager.start(context, token)
            else -> throw IllegalArgumentException("暂不支持的权限模式：$mode")
        }
        return Session(mode, port, token).also { session = it }
    }

    fun stop() {
        session = null
        runCatching { suProcess?.destroy() }
        runCatching { shizukuProcess?.destroy() }
        suProcess = null
        shizukuProcess = null
        runCatching { AdbManager.stop() }
    }

    private fun startWithSu(context: Context, token: String): Int {
        deployHelper(
            context,
            ProcessBuilder("su", "-c", "cat > $HELPER_PATH && chmod 700 $HELPER_PATH")
                .redirectErrorStream(true)
                .start(),
        )

        val process = ProcessBuilder("su", "-c", HELPER_PATH)
            .redirectErrorStream(true)
            .start()
        process.outputStream.write((token + "\n").toByteArray())
        process.outputStream.flush()
        val port = awaitPort(process.inputStream)
        suProcess = process
        return port
    }

    private fun startWithShizuku(context: Context, token: String): Int {
        if (!shizukuAvailable()) throw IllegalStateException("Shizuku 未运行")
        if (shizukuPermission() != PackageManager.PERMISSION_GRANTED) {
            throw IllegalStateException("未授予 Shizuku 权限")
        }
        deployHelper(
            context,
            shizukuNewProcess(arrayOf("sh", "-c", "cat > $HELPER_PATH && chmod 700 $HELPER_PATH")),
        )

        val process = shizukuNewProcess(arrayOf("sh", "-c", HELPER_PATH))
        process.outputStream.write((token + "\n").toByteArray())
        process.outputStream.flush()
        val port = awaitPort(process.inputStream)
        shizukuProcess = process
        return port
    }

    // ---------------------------------------------------------------------
    // 内部工具
    // ---------------------------------------------------------------------

    /**
     * 把辅助进程二进制写入 `/data/local/tmp`。
     *
     * 关键：必须通过**标准输入**传输。二进制约 1.8 MB，若塞进命令参数会超过
     * Linux 单个参数上限（`MAX_ARG_STRLEN` = 128 KiB），导致 `execve` 直接失败，
     * 这也是此前「启动失败」的原因。
     */
    private fun deployHelper(context: Context, process: Process) {
        val bytes = helperBytes(context)
        try {
            val out = process.outputStream
            var offset = 0
            val chunk = 64 * 1024
            while (offset < bytes.size) {
                val length = minOf(chunk, bytes.size - offset)
                out.write(bytes, offset, length)
                out.flush()
                offset += length
            }
            out.close()
        } catch (error: Exception) {
            runCatching { process.destroy() }
            throw IllegalStateException("写入高权限服务失败：${describe(error)}")
        }

        val finished = waitFor(process, 60000)
        val output = runCatching { process.inputStream.readBytes().decodeToString() }
            .getOrDefault("")
        if (!finished) {
            runCatching { process.destroy() }
            throw IllegalStateException("部署高权限服务超时")
        }
        val code = runCatching { process.exitValue() }.getOrDefault(0)
        if (code != 0) {
            throw IllegalStateException(
                "部署高权限服务失败（$code）：${output.trim().take(200)}",
            )
        }
    }

    private fun describe(error: Throwable): String =
        generateSequence(error) { it.cause }
            .map { it.javaClass.simpleName + (it.message?.let { m -> ": $m" } ?: "") }
            .joinToString(" <- ")

    /**
     * Shizuku 的 `newProcess` 在当前 API 版本为私有方法；通过反射调用（它是
     * 普通库方法，非系统隐藏 API）。
     */
    private val newProcessMethod: Method by lazy {
        Shizuku::class.java
            .getDeclaredMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java,
            )
            .apply { isAccessible = true }
    }

    private fun shizukuNewProcess(command: Array<String>): Process {
        return try {
            newProcessMethod.invoke(null, command, null, null) as Process
        } catch (error: java.lang.reflect.InvocationTargetException) {
            throw IllegalStateException(
                "Shizuku 启动进程失败：${describe(error.cause ?: error)}",
            )
        } catch (error: Exception) {
            throw IllegalStateException("Shizuku 启动进程失败：${describe(error)}")
        }
    }

    private fun waitFor(process: Process, timeoutMs: Long): Boolean {
        val thread = Thread { runCatching { process.waitFor() } }
        thread.isDaemon = true
        thread.start()
        thread.join(timeoutMs)
        return !thread.isAlive
    }

    private fun helperBytes(context: Context): ByteArray {
        val abi = supportedAbi()
        return context.assets.open("privd/$abi/ordo-privd").use { it.readBytes() }
    }

    private fun supportedAbi(): String {
        val known = setOf("arm64-v8a", "armeabi-v7a", "x86_64")
        return Build.SUPPORTED_ABIS.firstOrNull { it in known } ?: "arm64-v8a"
    }

    private fun awaitPort(input: InputStream, timeoutMs: Long = 20000): Int {
        val queue = LinkedBlockingQueue<String>()
        val reader = Thread {
            try {
                BufferedReader(InputStreamReader(input)).forEachLine { line ->
                    queue.put(line)
                }
            } catch (_: Exception) {
                // 进程结束或流关闭。
            }
        }
        reader.isDaemon = true
        reader.start()
        val deadline = System.currentTimeMillis() + timeoutMs
        while (true) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) break
            val line = queue.poll(remaining, TimeUnit.MILLISECONDS) ?: break
            if (line.startsWith(TAG)) {
                return line.substring(TAG.length).trim().toInt()
            }
        }
        throw IllegalStateException("高权限服务启动超时")
    }

    private fun randomToken(): String {
        val bytes = ByteArray(24)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
