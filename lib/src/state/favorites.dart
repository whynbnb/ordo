import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../services/ordo_service.dart';

/// 收藏夹全局状态。
class FavoritesStore extends ChangeNotifier {
  FavoritesStore._();

  static final FavoritesStore instance = FavoritesStore._();

  final OrdoService _service = OrdoService.instance;

  List<Favorite> _items = const [];
  bool _loaded = false;

  List<Favorite> get items => _items;
  bool get loaded => _loaded;

  bool contains(String path) => _items.any((favorite) => favorite.path == path);

  Future<void> loadIfNeeded() async {
    if (_loaded) return;
    await load();
  }

  Future<void> load() async {
    try {
      _items = await _service.favorites();
    } catch (_) {
      _items = const [];
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> add(String name, String path) async {
    _items = await _service.addFavorite(name, path);
    _loaded = true;
    notifyListeners();
  }

  Future<void> remove(String path) async {
    _items = await _service.removeFavorite(path);
    notifyListeners();
  }

  Future<void> toggle(String name, String path) async {
    if (contains(path)) {
      await remove(path);
    } else {
      await add(name, path);
    }
  }
}
