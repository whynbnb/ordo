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

  static Future<bool> openFile(
    String path, {
    String? mime,
    String? package,
    String? activity,
  }) async {
    return await _invokeBool('openFile', {
      'path': path,
      'mime': mime,
      'package': package,
      'activity': activity,
    });
  }

  /// 查询能处理某 MIME 的应用（用于设置「默认打开方式」）。
  static Future<List<Map<String, dynamic>>> resolveActivities(
    String mime,
  ) async {
    try {
      final result = await _channel.invokeListMethod<dynamic>(
        'resolveActivities',
        {'mime': mime},
      );
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
  // 应用内音频预览（系统 MediaPlayer）
  // -------------------------------------------------------------------------

  /// 加载音频，返回时长（毫秒）；失败返回 -1。
  static Future<int> audioLoad(String path) async {
    try {
      return await _channel.invokeMethod<int>('audioLoad', {'path': path}) ?? -1;
    } on PlatformException {
      return -1;
    } on MissingPluginException {
      return -1;
    }
  }

  static Future<void> audioPlay() => _invokeVoid('audioPlay');

  static Future<void> audioPause() => _invokeVoid('audioPause');

  static Future<void> audioSeek(int ms) async {
    try {
      await _channel.invokeMethod<void>('audioSeek', {'ms': ms});
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 忽略。
    }
  }

  static Future<void> audioStop() => _invokeVoid('audioStop');

  static Future<({int position, int duration, bool playing})>
  audioStatus() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'audioStatus',
      );
      return (
        position: (result?['position'] as num?)?.toInt() ?? 0,
        duration: (result?['duration'] as num?)?.toInt() ?? 0,
        playing: result?['playing'] as bool? ?? false,
      );
    } on PlatformException {
      return (position: 0, duration: 0, playing: false);
    } on MissingPluginException {
      return (position: 0, duration: 0, playing: false);
    }
  }

  static Future<void> _invokeVoid(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 忽略。
    }
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
  static void Function(String path)? _onOpenPath;
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
        case 'openPath':
          final path = call.arguments;
          if (path is String && path.isNotEmpty) _onOpenPath?.call(path);
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

  /// 监听由桌面快捷方式等触发的「打开指定路径」事件。
  static void setOpenPathHandler(void Function(String path) handler) {
    _ensureHandler();
    _onOpenPath = handler;
  }

  /// 桌面快捷方式的冷启动路径（消费后清空）。
  static Future<String?> consumeStartupPath() async {
    try {
      return await _channel.invokeMethod<String>('consumeStartupPath');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 是否支持固定桌面快捷方式。
  static Future<bool> shortcutSupported() async {
    return await _invokeBool('shortcutSupported', const {});
  }

  /// 为某个路径创建桌面快捷方式（系统会弹出固定确认）。
  static Future<bool> createShortcut(String name, String path) async {
    return await _invokeBool('createShortcut', {'name': name, 'path': path});
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

  /// PDF 页数（通过系统 `PdfRenderer`）。
  static Future<int> pdfPageCount(String path) async {
    try {
      return await _channel.invokeMethod<int>('pdfPageCount', {'path': path}) ??
          0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// 渲染 PDF 某一页为 JPEG 字节。
  static Future<Uint8List?> pdfPage(
    String path,
    int page, {
    int width = 1080,
  }) async {
    try {
      return await _channel.invokeMethod<Uint8List>('pdfPage', {
        'path': path,
        'page': page,
        'width': width,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 把本地图片设为系统壁纸。
  static Future<bool> setWallpaper(String path) async {
    return await _invokeBool('setWallpaper', {'path': path});
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
