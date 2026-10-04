package com.ordo.ordo

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.Settings
import android.webkit.MimeTypeMap
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
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
                    "paths" -> result.success(
                        mapOf(
                            "filesDir" to filesDir.absolutePath,
                            "cacheDir" to cacheDir.absolutePath,
                        )
                    )
                    else -> result.notImplemented()
                }
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
