import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/labels.dart';
import 'prefs_store.dart';

/// 文件 / 文件夹的颜色标签，按路径持久化到偏好。
class LabelStore extends ChangeNotifier {
  LabelStore._();

  static final LabelStore instance = LabelStore._();

  static const String _key = 'labels';

  Map<String, int> _labels = const {};
  bool _loaded = false;
  Future<void>? _loading;

  Future<void> loadIfNeeded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    await PrefsStore.instance.loadIfNeeded();
    final raw = PrefsStore.instance.value(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = (jsonDecode(raw) as Map).map(
          (key, value) => MapEntry(key.toString(), (value as num).toInt()),
        );
        _labels = map;
      } catch (_) {
        _labels = const {};
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 该路径的标签索引；未设置返回 null。
  int? indexFor(String path) => _labels[path];

  /// 该路径的标签颜色；未设置返回 null。
  Color? colorFor(String path) {
    final index = _labels[path];
    if (index == null || index < 0 || index >= labelPalette.length) return null;
    return labelPalette[index];
  }

  Future<void> setLabel(String path, int? index) => setLabels([path], index);

  Future<void> setLabels(List<String> paths, int? index) async {
    if (paths.isEmpty) return;
    final next = Map<String, int>.from(_labels);
    for (final path in paths) {
      if (index == null) {
        next.remove(path);
      } else {
        next[path] = index;
      }
    }
    _labels = next;
    notifyListeners();
    try {
      await PrefsStore.instance.setValue(_key, jsonEncode(next));
    } catch (_) {
      // 忽略持久化失败。
    }
  }
}
