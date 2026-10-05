import 'package:flutter/services.dart';

/// 与 Android 原生层交互：存储权限、打开 / 分享文件。
class PlatformService {
  PlatformService._();

  static const MethodChannel _channel = MethodChannel('ordo/platform');

  static Future<bool> hasStoragePermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasStoragePermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Android 11+ 会跳到系统设置；授权后需在应用恢复前台时重新检查。
  static Future<bool> requestStoragePermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestStoragePermission') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> openFile(String path, {String? mime}) async {
    return await _invokeBool('openFile', {'path': path, 'mime': mime});
  }

  static Future<bool> shareFile(String path, {String? mime}) async {
    return await _invokeBool('shareFile', {'path': path, 'mime': mime});
  }

  static Future<int> sdkInt() async {
    try {
      return await _channel.invokeMethod<int>('sdkInt') ?? 0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// 返回应用私有目录：`filesDir`（配置）与 `cacheDir`（下载缓存）。
  static Future<({String filesDir, String cacheDir})?> appPaths() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('paths');
      if (result == null) return null;
      return (
        filesDir: result['filesDir'] as String? ?? '',
        cacheDir: result['cacheDir'] as String? ?? '',
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Android `StorageManager` 中的卷信息（含可插拔 USB / 存储卡）。
  ///
  /// 非 Android 平台或原生层不可用时返回空列表，Rust 侧会退回自动探测。
  static Future<List<Map<String, dynamic>>> storageVolumes() async {
    try {
      final result = await _channel.invokeListMethod<dynamic>('storageVolumes');
      if (result == null) return const [];
      return result
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  // -------------------------------------------------------------------------
  // Android -> Dart 的异步事件（拖放、存储卷插拔）
  // -------------------------------------------------------------------------

  static void Function()? _onDragStarted;
  static void Function()? _onDragEntered;
  static void Function()? _onDragExited;
  static Future<void> Function(List<Map<String, dynamic>>)? _onDropped;
  static final List<void Function()> _storageListeners = <void Function()>[];
  static bool _handlerInstalled = false;

  /// 单例方法通道只能有一个 handler，这里统一分发拖放与存储事件。
  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'dragStarted':
          _onDragStarted?.call();
        case 'dragEntered':
          _onDragEntered?.call();
        case 'dragExited':
        case 'dragEnded':
          _onDragExited?.call();
        case 'dragDropped':
          final items = <Map<String, dynamic>>[];
          final raw = call.arguments;
          if (raw is List) {
            for (final entry in raw) {
              if (entry is Map) items.add(entry.cast<String, dynamic>());
            }
          }
          await _onDropped?.call(items);
        case 'storageChanged':
          for (final listener in List<void Function()>.of(_storageListeners)) {
            listener();
          }
      }
      return null;
    });
  }

  /// 注册来自 Android 的拖放事件（跨应用拖入文件）。
  static void setDropHandler({
    required void Function() onStarted,
    required void Function() onEntered,
    required void Function() onExited,
    required Future<void> Function(List<Map<String, dynamic>>) onDropped,
  }) {
    _ensureHandler();
    _onDragStarted = onStarted;
    _onDragEntered = onEntered;
    _onDragExited = onExited;
    _onDropped = onDropped;
  }

  /// 监听存储卷变化（插入 / 拔出 U 盘、存储卡）。可注册多个监听者。
  static void addStorageListener(void Function() listener) {
    _ensureHandler();
    _storageListeners.add(listener);
  }

  /// 通过 Android 媒体框架为视频生成一帧缩略图（JPEG 字节）。
  ///
  /// Rust 目前不解码视频流，这里借用系统 `MediaMetadataRetriever`；图片缩略图
  /// 仍由 Rust 完成。
  static Future<Uint8List?> videoThumbnail(String path) async {
    try {
      return await _channel.invokeMethod<Uint8List>('videoThumbnail', {
        'path': path,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool> _invokeBool(
    String method,
    Map<String, Object?> args,
  ) async {
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
