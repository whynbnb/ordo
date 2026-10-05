package me.whynbnb.ordo

import android.Manifest
import android.app.KeyguardManager
import android.app.WallpaperManager
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.drawable.Icon
import android.graphics.pdf.PdfRenderer
import android.hardware.usb.UsbManager
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.storage.StorageManager
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.DragEvent
import android.view.View
import android.webkit.MimeTypeMap
import java.io.ByteArrayOutputStream
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 只负责两件 Flutter 无法直接完成的事：
 * 1. 申请存储权限（Android 11+ 的「所有文件访问权限」或旧版的读写权限）。
 * 2. 通过 FileProvider 用系统意图打开 / 分享文件。
 *
 * 其余所有文件系统操作都交给 Rust 核心。
 */
class MainActivity : FlutterActivity() {

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingAuthResult: MethodChannel.Result? = null
    private var channel: MethodChannel? = null

    // 外部介质（U 盘 / 存储卡）插拔监听。
    private val mainHandler = Handler(Looper.getMainLooper())
    private var storageReceiver: BroadcastReceiver? = null
    private var lastVolumeSignature: String? = null
    private var pendingStorageCheck: Runnable? = null

    // 桌面快捷方式带来的待打开路径（冷启动）。
    private var pendingOpenPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasStoragePermission" -> result.success(hasStoragePermission())
                "requestStoragePermission" -> requestStoragePermission(result)
                "openFile" -> result.success(
                    viewFile(
                        call.argument("path"),
                        call.argument("mime"),
                        call.argument("package"),
                        call.argument("activity"),
                    )
                )
                "shareFile" -> result.success(
                    sendFile(call.argument("path"), call.argument("mime"))
                )
                "resolveActivities" -> result.success(
                    resolveActivities(call.argument("mime"))
                )
                "audioLoad" -> audioLoad(call.argument("path"), result)
                "audioPlay" -> {
                    AudioPlayerHolder.play()
                    result.success(true)
                }
                "audioPause" -> {
                    AudioPlayerHolder.pause()
                    result.success(true)
                }
                "audioSeek" -> {
                    AudioPlayerHolder.seek(call.argument<Int>("ms") ?: 0)
                    result.success(true)
                }
                "audioStatus" -> result.success(AudioPlayerHolder.status())
                "audioStop" -> {
                    AudioPlayerHolder.release()
                    AudioPlaybackService.stop(this)
                    result.success(true)
                }
                "shortcutSupported" -> result.success(shortcutSupported())
                "createShortcut" -> result.success(
                    createShortcut(
                        call.argument("name") ?: "",
                        call.argument("path") ?: "",
                    )
                )
                "consumeStartupPath" -> {
                    val path = pendingOpenPath
                    pendingOpenPath = null
                    result.success(path)
                }
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "lockAvailable" -> result.success(lockAvailable())
                "authenticate" -> authenticate(result)
                "transferNotify" -> {
                    ensureNotificationPermission()
                    TransferService.update(
                        this,
                        call.argument("title") ?: "安序 · 正在传输",
                        call.argument("text") ?: "",
                        call.argument<Int>("progress") ?: -1,
                    )
                    result.success(true)
                }
                "transferDone" -> {
                    TransferService.stop(this)
                    result.success(true)
                }
                "storageVolumes" -> result.success(storageVolumes())
                "videoThumbnail" -> result.success(videoThumbnail(call.argument("path")))
                "pdfPageCount" -> result.success(
                    pdfPageCount(call.argument("path"))
                )
                "pdfPage" -> result.success(
                    pdfPage(
                        call.argument("path"),
                        call.argument<Int>("page") ?: 0,
                        call.argument<Int>("width") ?: 1080,
                    )
                )
                "setWallpaper" -> result.success(
                    setWallpaper(call.argument<String>("path"))
                )
                "paths" -> result.success(
                    mapOf(
                        "filesDir" to filesDir.absolutePath,
                        "cacheDir" to cacheDir.absolutePath,
                    )
                )
                else -> result.notImplemented()
            }
        }

        setupDragAndDrop()
        registerStorageReceiver()

        // 记录初始卷状态，并处理「由 USB 插入意图启动」的情况。
        lastVolumeSignature = volumeSignature()
        if (intent?.action == UsbManager.ACTION_USB_DEVICE_ATTACHED) {
            scheduleStorageCheck()
        }
        pendingOpenPath = intent?.getStringExtra(EXTRA_OPEN_PATH)
    }

    // -----------------------------------------------------------------------
    // 外部介质：监听挂载 / 卸载与 USB 插拔，主动刷新并通知 Dart
    // -----------------------------------------------------------------------

    /**
     * 注册动态广播接收器。Android 的存储挂载广播要求带 `file` data scheme，
     * 而 USB 插拔意图没有 data，因此用两个 IntentFilter 分别匹配同一个接收器。
     */
    private fun registerStorageReceiver() {
        if (storageReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                scheduleStorageCheck()
            }
        }
        storageReceiver = receiver

        val mediaFilter = IntentFilter().apply {
            addAction(Intent.ACTION_MEDIA_MOUNTED)
            addAction(Intent.ACTION_MEDIA_UNMOUNTED)
            addAction(Intent.ACTION_MEDIA_EJECT)
            addAction(Intent.ACTION_MEDIA_REMOVED)
            addAction(Intent.ACTION_MEDIA_BAD_REMOVAL)
            addAction(Intent.ACTION_MEDIA_UNMOUNTABLE)
            addDataScheme("file")
        }
        val usbFilter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, mediaFilter, Context.RECEIVER_NOT_EXPORTED)
            registerReceiver(receiver, usbFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, mediaFilter)
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, usbFilter)
        }
    }

    /**
     * 插拔瞬间系统常会连发多个广播，且卷可能还没挂载完成。这里去抖并在稍后
     * 统一检查，避免重复刷新。
     */
    private fun scheduleStorageCheck() {
        pendingStorageCheck?.let { mainHandler.removeCallbacks(it) }
        val runnable = Runnable { checkStorageChanged() }
        pendingStorageCheck = runnable
        mainHandler.postDelayed(runnable, STORAGE_CHECK_DELAY_MS)
    }

    private fun checkStorageChanged() {
        pendingStorageCheck = null
        val signature = volumeSignature()
        if (signature == lastVolumeSignature) return
        lastVolumeSignature = signature
        channel?.invokeMethod("storageChanged", null)
    }

    private fun volumeSignature(): String {
        return storageVolumes().joinToString("|") { volume ->
            val path = volume["path"]?.toString() ?: ""
            val state = volume["state"]?.toString() ?: ""
            val removable = volume["removable"]?.toString() ?: ""
            "$path:$state:$removable"
        }
    }

    override fun onResume() {
        super.onResume()
        // 补偿可能错过的广播（例如进程在后台被回收后重建）。
        scheduleStorageCheck()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == UsbManager.ACTION_USB_DEVICE_ATTACHED) {
            scheduleStorageCheck()
        }
        intent.getStringExtra(EXTRA_OPEN_PATH)?.let { path ->
            channel?.invokeMethod("openPath", path)
        }
    }

    override fun onDestroy() {
        storageReceiver?.let { receiver ->
            runCatching { unregisterReceiver(receiver) }
        }
        storageReceiver = null
        pendingStorageCheck?.let { mainHandler.removeCallbacks(it) }
        pendingStorageCheck = null
        super.onDestroy()
    }

    // -----------------------------------------------------------------------
    // 跨应用拖放：接收其它应用（如相册）拖入的文件
    // -----------------------------------------------------------------------

    /**
     * Flutter 框架不暴露 Android 的系统拖放，这里直接监听根视图的 [DragEvent]。
     * 拖入时把 `content://` URI 打开成文件描述符并交给 Dart / Rust 落盘。
     */
    private fun setupDragAndDrop() {
        val target = findViewById<View>(android.R.id.content) ?: return
        target.setOnDragListener { _, event ->
            when (event.action) {
                DragEvent.ACTION_DRAG_STARTED -> {
                    channel?.invokeMethod("dragStarted", null)
                    true
                }
                DragEvent.ACTION_DRAG_ENTERED -> {
                    channel?.invokeMethod("dragEntered", null)
                    true
                }
                DragEvent.ACTION_DRAG_EXITED -> {
                    channel?.invokeMethod("dragExited", null)
                    true
                }
                DragEvent.ACTION_DRAG_ENDED -> {
                    channel?.invokeMethod("dragEnded", null)
                    true
                }
                DragEvent.ACTION_DROP -> {
                    handleDrop(event)
                    true
                }
                else -> false
            }
        }
    }

    private fun handleDrop(event: DragEvent) {
        // 先申请对拖入 URI 的临时读取权限，再打开描述符。
        try {
            requestDragAndDropPermissions(event)
        } catch (_: Exception) {
            // 部分场景（如 file://）无需申请。
        }

        val clip = event.clipData
        val items = mutableListOf<Map<String, Any?>>()
        if (clip != null) {
            val fallbackMime = clip.description?.getMimeType(0)
            for (index in 0 until clip.itemCount) {
                val uri = clip.getItemAt(index).uri ?: continue
                val fd = openReadDescriptor(uri) ?: continue
                items.add(
                    mapOf(
                        "fd" to fd,
                        "name" to (queryDisplayName(uri) ?: "imported"),
                        "mime" to (contentResolver.getType(uri) ?: fallbackMime ?: "*/*"),
                    )
                )
            }
        }
        channel?.invokeMethod("dragDropped", items)
    }

    /** 打开只读描述符并把所有权（fd）移交给 Rust。失败返回 null。 */
    private fun openReadDescriptor(uri: Uri): Int? {
        return try {
            if (uri.scheme == "file") {
                val path = uri.path ?: return null
                ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
                    .detachFd()
            } else {
                contentResolver.openFileDescriptor(uri, "r")?.detachFd()
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (column >= 0) cursor.getString(column) else null
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun hasStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    /**
     * 通过 StorageManager 枚举所有卷（含可插拔 USB / 存储卡）。
     * 目录路径仅在 Android 11（API 30）及以上可用；更早版本由 Rust 侧自行探测。
     */
    private fun storageVolumes(): List<Map<String, Any?>> {
        val manager = getSystemService(Context.STORAGE_SERVICE) as? StorageManager
            ?: return emptyList()
        val volumes = mutableListOf<Map<String, Any?>>()
        for (volume in manager.storageVolumes) {
            val directory = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                volume.directory?.absolutePath
            } else {
                null
            }
            volumes.add(
                mapOf(
                    "path" to directory,
                    "description" to volume.getDescription(this),
                    "removable" to volume.isRemovable,
                    "primary" to volume.isPrimary,
                    "state" to volume.state,
                    "uuid" to volume.uuid,
                )
            )
        }
        return volumes
    }

    /**
     * 借用系统媒体框架为视频抽一帧（JPEG）。视频解码不在 Rust 能力范围内，
     * 图片缩略图仍由 Rust 生成。
     */
    private fun videoThumbnail(path: String?): ByteArray? {
        if (path == null) return null
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val frame = retriever.getFrameAtTime(0) ?: return null
            val scaled = scaleToMax(frame, 256)
            val output = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 80, output)
            output.toByteArray()
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
                // 忽略释放异常。
            }
        }
    }

    private fun scaleToMax(bitmap: Bitmap, max: Int): Bitmap {
        val width = bitmap.width
        val height = bitmap.height
        if (width <= max && height <= max) return bitmap
        val ratio = max.toFloat() / maxOf(width, height)
        val targetWidth = (width * ratio).toInt().coerceAtLeast(1)
        val targetHeight = (height * ratio).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(bitmap, targetWidth, targetHeight, true)
    }

    // -----------------------------------------------------------------------
    // PDF 应用内预览（系统 PdfRenderer，逐页转 JPEG）
    // -----------------------------------------------------------------------

    private class PdfHandle(val renderer: PdfRenderer, val pfd: ParcelFileDescriptor) {
        fun close() {
            runCatching { renderer.close() }
            runCatching { pfd.close() }
        }
    }

    private fun openPdf(path: String?): PdfHandle? {
        if (path.isNullOrEmpty()) return null
        return try {
            val file = File(path)
            if (!file.exists()) return null
            val pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            PdfHandle(PdfRenderer(pfd), pfd)
        } catch (_: Exception) {
            null
        }
    }

    private fun pdfPageCount(path: String?): Int {
        val handle = openPdf(path) ?: return 0
        return try {
            handle.renderer.pageCount
        } catch (_: Exception) {
            0
        } finally {
            handle.close()
        }
    }

    private fun pdfPage(path: String?, pageIndex: Int, targetWidth: Int): ByteArray? {
        val handle = openPdf(path) ?: return null
        return try {
            val renderer = handle.renderer
            if (pageIndex < 0 || pageIndex >= renderer.pageCount) return null
            val page = renderer.openPage(pageIndex)
            try {
                val safeWidth = targetWidth.coerceIn(200, 2400)
                val ratio = safeWidth.toFloat() / page.width
                val width = safeWidth
                val height = (page.height * ratio).toInt().coerceAtLeast(1)
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                bitmap.eraseColor(android.graphics.Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val output = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, 80, output)
                bitmap.recycle()
                output.toByteArray()
            } finally {
                runCatching { page.close() }
            }
        } catch (_: Exception) {
            null
        } finally {
            handle.close()
        }
    }

    /** 把图片设为系统壁纸（需要本地可读文件路径）。 */
    private fun setWallpaper(path: String?): Boolean {
        val file = path?.let { File(it) } ?: return false
        if (!file.exists()) return false
        return try {
            val manager = WallpaperManager.getInstance(this)
            file.inputStream().use { manager.setStream(it) }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun requestStoragePermission(result: MethodChannel.Result) {
        if (hasStoragePermission()) {
            result.success(true)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                        .setData(Uri.parse("package:$packageName"))
                )
            } catch (_: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
            // 用户在系统设置授权后回到应用，Dart 侧会在 onResume 时重新检查。
            result.success(false)
        } else {
            pendingPermissionResult = result
            requestPermissions(
                arrayOf(
                    Manifest.permission.WRITE_EXTERNAL_STORAGE,
                    Manifest.permission.READ_EXTERNAL_STORAGE,
                ),
                REQUEST_STORAGE,
            )
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        @Suppress("DEPRECATION")
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_STORAGE) {
            pendingPermissionResult?.success(
                grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            )
            pendingPermissionResult = null
        }
    }

    // -----------------------------------------------------------------------
    // 应用锁：使用系统锁屏凭证（PIN / 图案 / 密码）验证
    // -----------------------------------------------------------------------

    private fun lockAvailable(): Boolean {
        val manager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            manager.isDeviceSecure
        } else {
            @Suppress("DEPRECATION")
            manager.isKeyguardSecure
        }
    }

    private fun authenticate(result: MethodChannel.Result) {
        if (pendingAuthResult != null) {
            result.success(false)
            return
        }
        val manager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (manager == null) {
            result.success(false)
            return
        }
        val intent = manager.createConfirmDeviceCredentialIntent("解锁安序", "验证设备锁屏凭证")
        if (intent == null) {
            result.success(false)
            return
        }
        pendingAuthResult = result
        try {
            startActivityForResult(intent, REQUEST_UNLOCK)
        } catch (_: Exception) {
            pendingAuthResult = null
            result.success(false)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_UNLOCK) {
            val pending = pendingAuthResult
            pendingAuthResult = null
            pending?.success(resultCode == RESULT_OK)
        }
    }

    private fun viewFile(
        path: String?,
        mime: String?,
        pkg: String?,
        activity: String?,
    ): Boolean {
        val file = path?.let { File(it) } ?: return false
        if (!file.exists()) return false
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime ?: guessMime(path))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            if (!pkg.isNullOrEmpty()) {
                // 用户指定的默认应用：直接跳到它；否则弹出选择器。
                if (!activity.isNullOrEmpty()) {
                    intent.component = ComponentName(pkg, activity)
                } else {
                    intent.setPackage(pkg)
                }
                startActivity(intent)
            } else {
                startActivity(Intent.createChooser(intent, "打开方式"))
            }
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    /** 查询能处理某 MIME 的应用（用于设置「默认打开方式」）。 */
    private fun resolveActivities(mime: String?): List<Map<String, Any?>> {
        val type = if (mime.isNullOrEmpty()) "*/*" else mime
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(Uri.parse("content://$packageName.fileprovider/"), type)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val infos = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.queryIntentActivities(
                    intent,
                    PackageManager.ResolveInfoFlags.of(
                        PackageManager.MATCH_DEFAULT_ONLY.toLong()
                    ),
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
            }
        } catch (_: Exception) {
            emptyList()
        }
        val seen = HashSet<String>()
        val apps = mutableListOf<Map<String, Any?>>()
        for (info in infos) {
            val info2 = info.activityInfo ?: continue
            val appPackage = info2.packageName ?: continue
            if (appPackage == packageName) continue
            if (!seen.add(appPackage)) continue
            apps.add(
                mapOf(
                    "label" to info.loadLabel(packageManager).toString(),
                    "package" to appPackage,
                    "activity" to info2.name,
                )
            )
        }
        apps.sortBy { (it["label"] as? String)?.lowercase().orEmpty() }
        return apps
    }

    // -----------------------------------------------------------------------
    // 桌面快捷方式（原生 ShortcutManager）
    // -----------------------------------------------------------------------

    private fun shortcutSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val manager = getSystemService(Context.SHORTCUT_SERVICE) as? ShortcutManager
            ?: return false
        return manager.isRequestPinShortcutSupported
    }

    private fun createShortcut(name: String, path: String): Boolean {
        if (!shortcutSupported() || path.isEmpty()) return false
        val manager = getSystemService(Context.SHORTCUT_SERVICE) as? ShortcutManager
            ?: return false
        return try {
            val launch = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                putExtra(EXTRA_OPEN_PATH, path)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            val label = name.ifEmpty { "安序" }
            val info = ShortcutInfo.Builder(this, "ordo:" + path.hashCode())
                .setShortLabel(label)
                .setLongLabel(label)
                .setIcon(Icon.createWithResource(this, R.mipmap.ic_launcher))
                .setIntent(launch)
                .build()
            manager.requestPinShortcut(info, null)
            true
        } catch (_: Exception) {
            false
        }
    }

    // -----------------------------------------------------------------------
    // 音频播放（前台服务 + MediaSession，支持后台与通知栏控制）
    // -----------------------------------------------------------------------

    private fun audioLoad(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.success(-1)
            return
        }
        ensureNotificationPermission()
        AudioPlaybackService.start(this)
        val name = File(path).name
        AudioPlayerHolder.load(this, path, name) { duration ->
            runCatching { result.success(duration) }
        }
    }

    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        try {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        } catch (_: Exception) {
            // 忽略。
        }
    }

    private fun sendFile(path: String?, mime: String?): Boolean {
        val file = path?.let { File(it) } ?: return false
        if (!file.exists()) return false
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mime ?: guessMime(path)
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "分享"))
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun guessMime(path: String): String {
        val ext = path.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
    }

    companion object {
        private const val CHANNEL = "ordo/platform"
        private const val REQUEST_STORAGE = 4711
        private const val REQUEST_NOTIFICATIONS = 4712
        private const val REQUEST_UNLOCK = 4713
        private const val STORAGE_CHECK_DELAY_MS = 500L
        private const val EXTRA_OPEN_PATH = "ordo_open_path"
    }
}
