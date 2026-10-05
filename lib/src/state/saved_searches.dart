import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import 'prefs_store.dart';

/// 一条保存的搜索。
class SavedSearch {
  const SavedSearch({
    required this.id,
    required this.name,
    required this.root,
    required this.query,
    required this.options,
  });

  final String id;
  final String name;
  final String root;
  final String query;
  final SearchOptions options;

  factory SavedSearch.fromJson(Map<String, dynamic> json) {
    return SavedSearch(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      root: json['root'] as String? ?? '',
      query: json['query'] as String? ?? '',
      options: SearchOptions.fromJson(
        (json['options'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'root': root,
    'query': query,
    'options': options.toJson(),
  };
}

/// 保存的搜索（持久化到界面偏好）。
class SavedSearchStore extends ChangeNotifier {
  SavedSearchStore._();

  static final SavedSearchStore instance = SavedSearchStore._();

  static const String _key = 'saved_searches';

  List<SavedSearch> _items = const [];
  bool _loaded = false;
  Future<void>? _loading;

  List<SavedSearch> get items => _items;

  Future<void> loadIfNeeded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    await PrefsStore.instance.loadIfNeeded();
    final raw = PrefsStore.instance.value(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        _items = list
            .map((e) => SavedSearch.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
      } catch (_) {
        _items = const [];
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<SavedSearch> add({
    required String name,
    required String root,
    required String query,
    required SearchOptions options,
  }) async {
    await loadIfNeeded();
    final item = SavedSearch(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      root: root,
      query: query,
      options: options,
    );
    _items = [..._items, item];
    await _persist();
    notifyListeners();
    return item;
  }

  Future<void> remove(String id) async {
    _items = _items.where((item) => item.id != id).toList();
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    await PrefsStore.instance.setValue(
      _key,
      jsonEncode([for (final item in _items) item.toJson()]),
    );
  }
}
