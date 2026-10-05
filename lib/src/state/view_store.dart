import 'package:flutter/foundation.dart';

import 'prefs_store.dart';
import '../i18n/i18n.dart';

/// 浏览页相关的显示偏好（列表 / 网格、图标大小、上移按钮、标签栏）。
class ViewStore extends ChangeNotifier {
  ViewStore._();

  static final ViewStore instance = ViewStore._();

  bool _grid = false;
  String _iconSize = 'medium';
  bool _showUp = false;
  bool _showTabBar = true;
  bool _appendOnHomeOpen = false;
  bool _loaded = false;

  bool get grid => _grid;
  String get iconSize => _iconSize;

  /// 是否在浏览页显示「向上一级」按钮（默认关闭）。
  bool get showUp => _showUp;

  /// 是否显示底部多标签栏（默认显示）；关闭后为单标签浏览模式。
  bool get showTabBar => _showTabBar;

  /// 从首页打开目录时是否附加到当前会话（默认关闭 = 重置为新会话）。
  bool get appendOnHomeOpen => _appendOnHomeOpen;

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
    _showTabBar = PrefsStore.instance.value('browser_show_tabs') != '0';
    _appendOnHomeOpen =
        PrefsStore.instance.value('browser_open_append') == '1';
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

  Future<void> setShowTabBar(bool value) async {
    _showTabBar = value;
    notifyListeners();
    await PrefsStore.instance.setValue('browser_show_tabs', value ? null : '0');
  }

  Future<void> setAppendOnHomeOpen(bool value) async {
    _appendOnHomeOpen = value;
    notifyListeners();
    await PrefsStore.instance.setValue(
      'browser_open_append',
      value ? '1' : null,
    );
  }

  String get iconSizeLabel => switch (_iconSize) {
    'small' => tr('小'),
    'large' => tr('大'),
    _ => tr('中'),
  };
}
