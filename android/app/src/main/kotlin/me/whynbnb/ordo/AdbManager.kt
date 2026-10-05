package me.whynbnb.ordo

import android.content.Context
import android.os.Build
import android.provider.Settings
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import io.github.muntashirakon.adb.AdbStream
import io.github.muntashirakon.adb.android.AndroidUtils
import java.io.File
import java.io.InputStream
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import java.util.Random
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import android.sun.security.x509.AlgorithmId
import android.sun.security.x509.CertificateAlgorithmId
import android.sun.security.x509.CertificateExtensions
import android.sun.security.x509.CertificateIssuerName
import android.sun.security.x509.CertificateSerialNumber
import android.sun.security.x509.CertificateSubjectName
import android.sun.security.x509.CertificateValidity
import android.sun.security.x509.CertificateVersion
import android.sun.security.x509.CertificateX509Key
import android.sun.security.x509.KeyIdentifier
import android.sun.security.x509.PrivateKeyUsageExtension
import android.sun.security.x509.SubjectKeyIdentifierExtension
import android.sun.security.x509.X500Name
import android.sun.security.x509.X509CertImpl
import android.sun.security.x509.X509CertInfo

private const val ADB_HELPER_PATH = "/data/local/tmp/ordo-privd"
private const val ADB_TAG = "ORDO_PRIVD "

/**
 * 「ADB 模式」：通过设备自身的无线调试直接连接 adbd，以 shell（uid 2000）身份
 * 运行辅助进程，能力与 Shizuku 相同。密钥对自签名并持久化，首次需与设备配对。
 */
object AdbManager {
    private var connection: OrdoAdbConnection? = null
    private var daemon: AdbStream? = null

    fun available(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        return runCatching {
            Settings.Global.getInt(context.contentResolver, "adb_wifi_enabled", 0) == 1
        }.getOrDefault(false)
    }

    /** 本机 Wi-Fi 地址，用于预填配对主机。 */
    fun hostIp(context: Context): String? =
        runCatching { AndroidUtils.getHostIpAddress(context) }.getOrNull()

    /** 与设备配对（配对端口与验证码来自「使用配对码配对设备」弹窗）。 */
    fun pair(context: Context, host: String, port: Int, code: String): Boolean {
        return conn(context).pair(host, port, code)
    }

    /** 部署并启动辅助进程，返回监听端口。 */
    fun start(context: Context, token: String): Int {
        val manager = conn(context)
        runCatching { manager.disconnect() }
        if (!manager.autoConnect(context, 15000)) {
            throw IllegalStateException("无法连接 ADB（请确认已开启无线调试并已配对）")
        }

        val bytes = helperBytes(context)
        val deploy = manager.openStream("shell:cat > $ADB_HELPER_PATH")
        val deployOut = deploy.openOutputStream()
        deployOut.write(bytes)
        deployOut.flush()
        runCatching { deploy.close() }
        runCatching { shell(manager, "chmod 700 $ADB_HELPER_PATH") }

        val stream = manager.openStream("shell:$ADB_HELPER_PATH")
        val daemonOut = stream.openOutputStream()
        daemonOut.write((token + "\n").toByteArray())
        daemonOut.flush()
        val port = awaitPort(stream.openInputStream())
        daemon = stream
        return port
    }

    fun stop() {
        runCatching { daemon?.close() }
        daemon = null
        runCatching { connection?.disconnect() }
        connection = null
    }

    private fun conn(context: Context): OrdoAdbConnection {
        return connection ?: OrdoAdbConnection(context).also { connection = it }
    }

    private fun shell(manager: OrdoAdbConnection, command: String): String {
        val stream = manager.openStream("shell:$command")
        val output = runCatching {
            stream.openInputStream().readBytes().decodeToString()
        }.getOrDefault("")
        runCatching { stream.close() }
        return output
    }

    private fun helperBytes(context: Context): ByteArray {
        val known = setOf("arm64-v8a", "armeabi-v7a", "x86_64")
        val abi = Build.SUPPORTED_ABIS.firstOrNull { it in known } ?: "arm64-v8a"
        return context.assets.open("privd/$abi/ordo-privd").use { it.readBytes() }
    }

    private fun awaitPort(input: InputStream, timeoutMs: Long = 20000): Int {
        val queue = LinkedBlockingQueue<String>()
        val reader = Thread {
            try {
                val buffered = input.bufferedReader()
                while (true) {
                    val line = buffered.readLine() ?: break
                    queue.put(line)
                }
            } catch (_: Exception) {
                // 流关闭。
            }
        }
        reader.isDaemon = true
        reader.start()
        val deadline = System.currentTimeMillis() + timeoutMs
        while (true) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) break
            val line = queue.poll(remaining, TimeUnit.MILLISECONDS) ?: break
            if (line.startsWith(ADB_TAG)) {
                return line.substring(ADB_TAG.length).trim().toInt()
            }
        }
        throw IllegalStateException("ADB 高权限服务启动超时")
    }
}

/** libadb 的连接管理器：提供持久化的 RSA 密钥与自签名证书。 */
class OrdoAdbConnection(context: Context) : AbsAdbConnectionManager() {
    private val privateKey: PrivateKey
    private val certificate: Certificate

    init {
        val dir = File(context.filesDir, "adb").apply { mkdirs() }
        val keyFile = File(dir, "key.pk8")
        val certFile = File(dir, "cert.der")
        if (keyFile.isFile && certFile.isFile) {
            privateKey = KeyFactory.getInstance("RSA")
                .generatePrivate(PKCS8EncodedKeySpec(keyFile.readBytes()))
            certificate = certFile.inputStream().use {
                CertificateFactory.getInstance("X.509").generateCertificate(it)
            }
        } else {
            val generator = KeyPairGenerator.getInstance("RSA")
            generator.initialize(2048, SecureRandom.getInstance("SHA1PRNG"))
            val pair = generator.generateKeyPair()
            privateKey = pair.private
            certificate = selfSigned(pair)
            keyFile.writeBytes(privateKey.encoded)
            certFile.writeBytes(certificate.encoded)
        }
        setApi(Build.VERSION.SDK_INT)
        setTimeout(10, TimeUnit.SECONDS)
    }

    override fun getPrivateKey(): PrivateKey = privateKey

    override fun getCertificate(): Certificate = certificate

    override fun getDeviceName(): String = "Ordo"

    private fun selfSigned(pair: KeyPair): Certificate {
        val publicKey = pair.public
        val algorithm = "SHA512withRSA"
        val notBefore = Date()
        val notAfter = Date(System.currentTimeMillis() + 10L * 365 * 24 * 3600 * 1000)
        val extensions = CertificateExtensions()
        extensions.set(
            "SubjectKeyIdentifier",
            SubjectKeyIdentifierExtension(KeyIdentifier(publicKey).identifier),
        )
        extensions.set("PrivateKeyUsage", PrivateKeyUsageExtension(notBefore, notAfter))
        val subject = X500Name("CN=Ordo")
        val info = X509CertInfo()
        info.set(X509CertInfo.VERSION, CertificateVersion(CertificateVersion.V3))
        info.set(
            X509CertInfo.SERIAL_NUMBER,
            CertificateSerialNumber(Random().nextInt() and Int.MAX_VALUE),
        )
        info.set(X509CertInfo.ALGORITHM_ID, CertificateAlgorithmId(AlgorithmId.get(algorithm)))
        info.set(X509CertInfo.SUBJECT, CertificateSubjectName(subject))
        info.set(X509CertInfo.KEY, CertificateX509Key(publicKey))
        info.set(X509CertInfo.VALIDITY, CertificateValidity(notBefore, notAfter))
        info.set(X509CertInfo.ISSUER, CertificateIssuerName(subject))
        info.set(X509CertInfo.EXTENSIONS, extensions)
        val impl = X509CertImpl(info)
        impl.sign(privateKey, algorithm)
        return impl
    }
}
