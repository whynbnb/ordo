import 'package:flutter/foundation.dart';

import 'prefs_store.dart';
import '../i18n/i18n.dart';

/// 文件列表的显示方式（列表 / 网格、图标大小）。
class ViewStore extends ChangeNotifier {
  ViewStore._();

  static final ViewStore instance = ViewStore._();

  bool _grid = false;
  String _iconSize = 'medium';
  bool _showUp = false;
  bool _loaded = false;

  bool get grid => _grid;
  String get iconSize => _iconSize;

  /// 是否在浏览页显示「向上一级」按钮（默认关闭）。
  bool get showUp => _showUp;
  bool get loaded => _loaded;

  /// 网格每格的目标边长（像素）。
  double get tileExtent => switch (_iconSize) {
    'small' => 88,
    'large' => 148,
    _ => 112,
  };

  /// 网格内图标的显示边长。
  double get iconExtent => switch (_iconSize) {
    'small' => 36,
    'large' => 72,
    _ => 52,
  };

  Future<void> loadIfNeeded() async {
    if (_loaded) return;
    await PrefsStore.instance.loadIfNeeded();
    _grid = PrefsStore.instance.value('browser_view') == 'grid';
    _iconSize = PrefsStore.instance.value('browser_icon_size') ?? 'medium';
    _showUp = PrefsStore.instance.value('browser_show_up') == '1';
    _loaded = true;
    notifyListeners();
  }

  Future<void> toggleGrid() async {
    _grid = !_grid;
    notifyListeners();
    await PrefsStore.instance.setValue('browser_view', _grid ? 'grid' : 'list');
  }

  Future<void> setIconSize(String size) async {
    _iconSize = size;
    notifyListeners();
    await PrefsStore.instance.setValue('browser_icon_size', size);
  }

  Future<void> setShowUp(bool value) async {
    _showUp = value;
    notifyListeners();
    await PrefsStore.instance.setValue('browser_show_up', value ? '1' : null);
  }

  String get iconSizeLabel => switch (_iconSize) {
    'small' => tr('小'),
    'large' => tr('大'),
    _ => tr('中'),
  };
}
