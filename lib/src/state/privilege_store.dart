import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/ordo_service.dart';
import '../services/platform_service.dart';
import 'prefs_store.dart';

/// 高权限模式（Root / Shizuku / ADB）的状态与切换。
///
/// 模式本身由原生层负责部署并启动以 shell / root 身份运行的辅助进程，
/// 再把本地端口与令牌交给 Rust 核心（`OrdoService.privConfigure`）。
class PrivilegeStore extends ChangeNotifier {
  PrivilegeStore._();

  static final PrivilegeStore instance = PrivilegeStore._();

  static const String _key = 'priv_mode';

  String _mode = 'off';
  bool _active = false;
  bool _busy = false;
  String? _error;

  bool _rootAvailable = false;
  bool _shizukuAvailable = false;
  bool _adbAvailable = false;
  int _shizukuPermission = -1;
  String? _hostIp;
  bool _loaded = false;

  /// `off` / `root` / `shizuku` / `adb`
  String get mode => _mode;
  bool get active => _active;
  bool get busy => _busy;
  String? get error => _error;
  bool get rootAvailable => _rootAvailable;
  bool get shizukuAvailable => _shizukuAvailable;
  bool get adbAvailable => _adbAvailable;
  bool get shizukuGranted => _shizukuPermission == 0;
  String? get hostIp => _hostIp;
  bool get loaded => _loaded;

  Future<void> load() async {
    await PrefsStore.instance.loadIfNeeded();
    final raw = PrefsStore.instance.value(_key);
    _mode = (raw == 'root' || raw == 'shizuku' || raw == 'adb') ? raw! : 'off';
    _loaded = true;
    notifyListeners();
  }

  /// 探测各模式是否可用。
  Future<void> detect() async {
    final info = await PlatformService.privDetect();
    _rootAvailable = info['root'] == true;
    _shizukuAvailable = info['shizuku'] == true;
    _adbAvailable = info['adb'] == true;
    _shizukuPermission = (info['shizukuPermission'] as num?)?.toInt() ?? -1;
    _hostIp = info['hostIp'] as String?;
    notifyListeners();
  }

  /// 请求 Shizuku 授权。
  Future<bool> requestShizuku() async {
    final granted = await PlatformService.privShizukuRequest();
    await detect();
    return granted;
  }

  /// ADB 模式：与设备无线调试配对。
  Future<bool> pairAdb({
    required String host,
    required int port,
    required String code,
  }) async {
    final paired = await PlatformService.privAdbPair(
      host: host,
      port: port,
      code: code,
    );
    if (paired) {
      await detect();
    }
    return paired;
  }

  /// 启用指定模式。
  Future<bool> activate(String mode) async {
    if (mode == _mode && _active) return true;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final session = await PlatformService.privStart(mode);
      final port = (session['port'] as num).toInt();
      final token = session['token'] as String;
      OrdoService.instance.privConfigure(port: port, token: token, mode: mode);
      _mode = mode;
      _active = true;
      await PrefsStore.instance.setValue(_key, mode);
      return true;
    } catch (error) {
      _error = error is PlatformException
          ? (error.message ?? error.code)
          : '$error';
      _active = false;
      _mode = 'off';
      await PrefsStore.instance.setValue(_key, null);
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 关闭高权限模式。
  Future<void> deactivate() async {
    _busy = true;
    notifyListeners();
    try {
      OrdoService.instance.privClear();
    } catch (_) {
      // 忽略：核心未加载或未配置。
    }
    await PlatformService.privStop();
    _mode = 'off';
    _active = false;
    _error = null;
    await PrefsStore.instance.setValue(_key, null);
    _busy = false;
    notifyListeners();
  }

  /// 启动时恢复上次启用的模式（辅助进程可能已随系统重启消失）。
  Future<void> restore() async {
    if (_mode == 'off') return;
    await activate(_mode);
  }
}
