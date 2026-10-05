import 'package:flutter/foundation.dart';
import '../i18n/i18n.dart';
import 'prefs_store.dart';

enum SortField { name, size, modified, type }

extension SortFieldLabel on SortField {
  String get label => switch (this) {
    SortField.name => tr('名称'),
    SortField.size => tr('大小'),
    SortField.modified => tr('修改时间'),
    SortField.type => tr('类型'),
  };
}

/// 全局显示 / 排序偏好（内存内保存，重启后重置）。
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  static const String _showHiddenKey = 'browser_show_hidden';

  bool _showHidden = false;
  SortField _sortField = SortField.name;
  bool _sortAscending = true;
  bool _loaded = false;

  bool get showHidden => _showHidden;
  SortField get sortField => _sortField;
  bool get sortAscending => _sortAscending;
  bool get loaded => _loaded;

  /// 载入持久化偏好（目前仅「显示隐藏文件」；排序仍为会话内）。
  Future<void> load() async {
    if (_loaded) return;
    await PrefsStore.instance.loadIfNeeded();
    _showHidden = PrefsStore.instance.value(_showHiddenKey) == '1';
    _loaded = true;
    notifyListeners();
  }

  set showHidden(bool value) {
    if (_showHidden == value) return;
    _showHidden = value;
    notifyListeners();
    PrefsStore.instance.setValue(_showHiddenKey, value ? '1' : null);
  }

  set sortField(SortField value) {
    if (_sortField == value) return;
    _sortField = value;
    notifyListeners();
  }

  set sortAscending(bool value) {
    if (_sortAscending == value) return;
    _sortAscending = value;
    notifyListeners();
  }

  void toggleDirection() => sortAscending = !_sortAscending;
}
