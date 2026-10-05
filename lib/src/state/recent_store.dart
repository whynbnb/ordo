import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'prefs_store.dart';

/// 一条最近访问记录。
class RecentItem {
  const RecentItem({
    required this.path,
    required this.name,
    required this.isDir,
    required this.time,
  });

  final String path;
  final String name;
  final bool isDir;
  final int time;

  factory RecentItem.fromJson(Map<String, dynamic> json) {
    return RecentItem(
      path: json['path'] as String? ?? '',
      name: json['name'] as String? ?? '',
      isDir: json['is_dir'] as bool? ?? false,
      time: (json['time'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'is_dir': isDir,
    'time': time,
  };
}

/// 最近访问的文件 / 文件夹，持久化在应用私有目录。
class RecentStore extends ChangeNotifier {
  RecentStore._();

  static final RecentStore instance = RecentStore._();

  static const String _key = 'recent_items';
  static const int _max = 50;

  List<RecentItem> _items = const [];
  bool _loaded = false;
  Future<void>? _loading;

  List<RecentItem> get items => _items;

  Future<void> loadIfNeeded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    await PrefsStore.instance.loadIfNeeded();
    final raw = PrefsStore.instance.value(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List)
            .whereType<Map>()
            .map((e) => RecentItem.fromJson(e.cast<String, dynamic>()))
            .toList();
        _items = list;
      } catch (_) {
        _items = const [];
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 记录一次访问（去重并按时间排序，最多保留 [_max] 条）。
  void record(String path, String name, bool isDir) {
    final item = RecentItem(
      path: path,
      name: name,
      isDir: isDir,
      time: DateTime.now().millisecondsSinceEpoch,
    );
    _items = [item, ..._items.where((e) => e.path != path)].take(_max).toList();
    notifyListeners();
    _persist();
  }

  Future<void> clear() async {
    _items = const [];
    notifyListeners();
    await PrefsStore.instance.setValue(_key, null);
  }

  /// 删除单条最近访问记录。
  Future<void> remove(String path) async {
    final next = _items.where((item) => item.path != path).toList();
    if (next.length == _items.length) return;
    _items = next;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await PrefsStore.instance.setValue(
        _key,
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      // 忽略持久化失败。
    }
  }
}
