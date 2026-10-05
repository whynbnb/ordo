package me.whynbnb.ordo

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import rikka.shizuku.Shizuku
import java.io.BufferedReader
import java.io.InputStream
import java.io.InputStreamReader
import java.lang.reflect.Method
import java.security.SecureRandom
import java.util.concurrent.CompletableFuture
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

    fun detect(): Map<String, Any> {
        val shizukuBinder = runCatching { Shizuku.pingBinder() }.getOrDefault(false)
        val shizukuPermission = if (shizukuBinder) shizukuPermission() else -1
        return mapOf(
            "root" to rootAvailable(),
            "shizuku" to shizukuBinder,
            "shizukuPermission" to shizukuPermission,
            "adb" to false,
            "active" to (session != null),
            "mode" to (session?.mode ?: "off"),
        )
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

    fun shizukuAvailable(): Boolean = runCatching { Shizuku.pingBinder() }.getOrDefault(false)

    fun shizukuPermission(): Int =
        runCatching { Shizuku.checkSelfPermission() }
            .getOrDefault(PackageManager.PERMISSION_DENIED)

    /** 请求 Shizuku 授权，返回是否已授权。 */
    fun requestShizukuPermission(): Boolean {
        if (shizukuPermission() == PackageManager.PERMISSION_GRANTED) return true
        val future = CompletableFuture<Boolean>()
        permissionFuture = future
        return try {
            Shizuku.requestPermission(REQUEST_CODE)
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
    }

    private fun startWithSu(context: Context, token: String): Int {
        val deploy = ProcessBuilder("su", "-c", deployScript(context))
            .redirectErrorStream(true)
            .start()
        deploy.outputStream.close()
        if (!waitFor(deploy, 30000)) {
            deploy.destroy()
            throw IllegalStateException("部署高权限服务超时")
        }

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
        val deploy = shizukuNewProcess(arrayOf("sh", "-c", deployScript(context)))
        deploy.outputStream.close()
        if (!waitFor(deploy, 30000)) {
            deploy.destroy()
            throw IllegalStateException("部署高权限服务超时")
        }

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
        return newProcessMethod.invoke(null, command, null, null) as Process
    }

    private fun waitFor(process: Process, timeoutMs: Long): Boolean {
        val thread = Thread { runCatching { process.waitFor() } }
        thread.isDaemon = true
        thread.start()
        thread.join(timeoutMs)
        return !thread.isAlive
    }

    private fun deployScript(context: Context): String {
        val encoded =
            android.util.Base64.encodeToString(helperBytes(context), android.util.Base64.NO_WRAP)
        return buildString {
            append("mkdir -p /data/local/tmp\n")
            append("base64 -d > $HELPER_PATH <<'ORDO_PRIVD_EOF'\n")
            append(encoded)
            append("\nORDO_PRIVD_EOF\n")
            append("chmod 700 $HELPER_PATH\n")
        }
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
