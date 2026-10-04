package com.ordo.ordo

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
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
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasStoragePermission" -> result.success(hasStoragePermission())
                "requestStoragePermission" -> requestStoragePermission(result)
                "openFile" -> result.success(
                    viewFile(call.argument("path"), call.argument("mime"))
                )
                "shareFile" -> result.success(
                    sendFile(call.argument("path"), call.argument("mime"))
                )
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "storageVolumes" -> result.success(storageVolumes())
                "videoThumbnail" -> result.success(videoThumbnail(call.argument("path")))
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

    private fun viewFile(path: String?, mime: String?): Boolean {
        val file = path?.let { File(it) } ?: return false
        if (!file.exists()) return false
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime ?: guessMime(path))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "打开方式"))
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: Exception) {
            false
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
    }
}
