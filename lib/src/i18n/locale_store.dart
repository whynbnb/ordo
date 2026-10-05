import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../state/prefs_store.dart';

/// 界面语言：跟随系统 / 简体中文 / English。
class LocaleStore extends ChangeNotifier {
  LocaleStore._();

  static final LocaleStore instance = LocaleStore._();

  static const String _key = 'locale';

  String _mode = 'system';
  bool _loaded = false;

  /// `system` / `zh` / `en`
  String get mode => _mode;
  bool get loaded => _loaded;

  Future<void> load() async {
    await PrefsStore.instance.loadIfNeeded();
    final raw = PrefsStore.instance.value(_key);
    _mode = (raw == 'zh' || raw == 'en') ? raw! : 'system';
    _loaded = true;
    notifyListeners();
  }

  Future<void> setMode(String mode) async {
    _mode = (mode == 'zh' || mode == 'en') ? mode : 'system';
    notifyListeners();
    if (_mode == 'system') {
      await PrefsStore.instance.setValue(_key, null);
    } else {
      await PrefsStore.instance.setValue(_key, _mode);
    }
  }

  /// 是否应显示英文。
  bool get isEnglish {
    if (_mode == 'en') return true;
    if (_mode == 'zh') return false;
    final code = ui.PlatformDispatcher.instance.locale.languageCode
        .toLowerCase();
    return code.startsWith('en');
  }

  /// MaterialApp 的 locale（null 表示跟随系统）。
  ui.Locale? get locale => switch (_mode) {
    'zh' => const ui.Locale('zh'),
    'en' => const ui.Locale('en'),
    _ => null,
  };
}
