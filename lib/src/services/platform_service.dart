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
