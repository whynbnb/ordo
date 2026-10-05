import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/file_types.dart';
import '../services/ordo_service.dart';

/// 一个「默认打开方式」目标应用。
class OpenWithTarget {
  const OpenWithTarget({
    required this.package,
    required this.activity,
    required this.label,
  });

  final String package;
  final String activity;
  final String label;

  factory OpenWithTarget.fromJson(Map<String, dynamic> json) {
    return OpenWithTarget(
      package: json['package'] as String? ?? '',
      activity: json['activity'] as String? ?? '',
      label: json['label'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'package': package,
    'activity': activity,
    'label': label,
  };
}

/// 「默认打开方式」的分类。
class OpenWithCategory {
  const OpenWithCategory(this.key, this.label, this.mime);

  final String key;
  final String label;
  final String mime;
}

List<OpenWithCategory> get openWithCategories => [
  OpenWithCategory('image', '图片', 'image/*'),
  OpenWithCategory('audio', '音频', 'audio/*'),
  OpenWithCategory('video', '视频', 'video/*'),
  OpenWithCategory('text', '文本', 'text/plain'),
  OpenWithCategory('pdf', 'PDF', 'application/pdf'),
  OpenWithCategory('apk', '安装包', 'application/vnd.android.package-archive'),
  OpenWithCategory('other', '其它', '*/*'),
];

String _key(String category) => 'open_with.$category';

/// 界面偏好：持久化到应用私有目录，由 Rust 读写。
class PrefsStore extends ChangeNotifier {
  PrefsStore._();

  static final PrefsStore instance = PrefsStore._();

  Map<String, String> _values = const {};
  bool _loaded = false;
  Future<void>? _loading;

  Future<void> loadIfNeeded() {
    // 配置目录就绪前不读取，避免把空偏好缓存下来导致设置看起来被重置。
    if (!OrdoService.instance.configReady) return Future.value();
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  /// 重新从磁盘读取（配置目录就绪 / 外部修改后调用）。
  Future<void> reload() async {
    if (!OrdoService.instance.configReady) return;
    _loaded = false;
    _loading = null;
    await loadIfNeeded();
  }

  Future<void> _load() async {
    try {
      _values = await OrdoService.instance.prefsAll();
    } catch (_) {
      _values = const {};
    }
    _loaded = true;
    notifyListeners();
  }

  /// 扩展名对应的默认打开应用；未设置返回 null（表示每次询问）。
  OpenWithTarget? targetFor(String extension) =>
      targetForCategory(openWithCategory(extension));

  OpenWithTarget? targetForCategory(String category) {
    final raw = _values[_key(category)];
    if (raw == null || raw.isEmpty) return null;
    try {
      return OpenWithTarget.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 读取任意偏好字符串。
  String? value(String key) => _values[key];

  /// 写入 / 删除任意偏好字符串。
  Future<void> setValue(String key, String? value) async {
    if (value == null) {
      await OrdoService.instance.prefRemove(key);
      _values = {..._values}..remove(key);
    } else {
      await OrdoService.instance.prefSet(key, value);
      _values = {..._values, key: value};
    }
    notifyListeners();
  }

  Future<void> setTarget(String category, OpenWithTarget? target) async {
    final key = _key(category);
    if (target == null) {
      await setValue(key, null);
    } else {
      await setValue(key, jsonEncode(target.toJson()));
    }
  }
}
