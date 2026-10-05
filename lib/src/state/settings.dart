import 'package:flutter/foundation.dart';
import '../i18n/i18n.dart';

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

  bool _showHidden = false;
  SortField _sortField = SortField.name;
  bool _sortAscending = true;

  bool get showHidden => _showHidden;
  SortField get sortField => _sortField;
  bool get sortAscending => _sortAscending;

  set showHidden(bool value) {
    if (_showHidden == value) return;
    _showHidden = value;
    notifyListeners();
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
