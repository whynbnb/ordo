import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/ordo_exception.dart';
import '../services/ordo_service.dart';
import 'settings.dart';

class BrowserController extends ChangeNotifier {
  BrowserController({required String initialPath, OrdoService? service})
    : _path = initialPath,
      _service = service ?? OrdoService.instance {
    _settings.addListener(_onSettingsChanged);
  }

  final OrdoService _service;
  final AppSettings _settings = AppSettings.instance;

  String _path;
  List<FileEntry> _allEntries = const [];
  List<FileEntry>? _visibleCache;
  bool _loading = false;
  String? _error;
  final Set<String> _selected = {};

  String get path => _path;
  bool get loading => _loading;
  String? get error => _error;
  Set<String> get selectedPaths => _selected;
  bool get selectionMode => _selected.isNotEmpty;
  int get selectedCount => _selected.length;
  bool get showHidden => _settings.showHidden;
  SortField get sortField => _settings.sortField;
  bool get sortAscending => _settings.sortAscending;

  void _onSettingsChanged() {
    _visibleCache = null;
    notifyListeners();
  }

  List<FileEntry> get entries {
    final cached = _visibleCache;
    if (cached != null) return cached;
    final visible = _settings.showHidden
        ? [..._allEntries]
        : _allEntries.where((e) => !e.hidden).toList();
    visible.sort(_compare);
    _visibleCache = visible;
    return visible;
  }

  List<FileEntry> get selectedEntries =>
      _allEntries.where((e) => _selected.contains(e.path)).toList();

  FileEntry? get singleSelected {
    final list = selectedEntries;
    return list.length == 1 ? list.first : null;
  }

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _service.listDir(_path);
      _allEntries = result;
      _visibleCache = null;
      _selected.removeWhere((p) => !result.any((e) => e.path == p));
    } on OrdoException catch (e) {
      _error = e.message;
      _allEntries = const [];
      _visibleCache = null;
    } catch (e) {
      _error = '加载失败：$e';
      _allEntries = const [];
      _visibleCache = null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> navigateTo(String newPath) async {
    _path = newPath;
    _selected.clear();
    await load();
  }

  Future<void> refresh() => load();

  void toggleSelected(String entryPath) {
    if (!_selected.remove(entryPath)) {
      _selected.add(entryPath);
    }
    notifyListeners();
  }

  bool isSelected(String entryPath) => _selected.contains(entryPath);

  void selectAll() {
    _selected
      ..clear()
      ..addAll(entries.map((e) => e.path));
    notifyListeners();
  }

  /// 反选当前可见条目。
  void invertSelection() {
    final next = <String>{
      for (final entry in entries)
        if (!_selected.contains(entry.path)) entry.path,
    };
    _selected
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  /// 按条件选择（清空后选中所有满足条件的可见条目）。
  void selectMatching(bool Function(FileEntry entry) test) {
    _selected
      ..clear()
      ..addAll(entries.where(test).map((e) => e.path));
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty) return;
    _selected.clear();
    notifyListeners();
  }

  void setSortField(SortField field) {
    if (_settings.sortField == field) {
      _settings.toggleDirection();
    } else {
      _settings.sortField = field;
      _settings.sortAscending = true;
    }
  }

  void setShowHidden(bool value) => _settings.showHidden = value;

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  int _compare(FileEntry a, FileEntry b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    final base = switch (_settings.sortField) {
      SortField.name => _naturalCompare(a.name, b.name),
      SortField.size => a.size.compareTo(b.size),
      SortField.modified => a.modified.compareTo(b.modified),
      SortField.type => _typeCompare(a, b),
    };
    return _settings.sortAscending ? base : -base;
  }

  int _typeCompare(FileEntry a, FileEntry b) {
    final byExt = a.extension.compareTo(b.extension);
    return byExt != 0 ? byExt : _naturalCompare(a.name, b.name);
  }
}

/// 自然排序：`file2` 在 `file10` 之前。
int _naturalCompare(String a, String b) {
  final ra = a.toLowerCase();
  final rb = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < ra.length && j < rb.length) {
    final ca = ra.codeUnitAt(i);
    final cb = rb.codeUnitAt(j);
    final da = _isDigit(ca);
    final db = _isDigit(cb);
    if (da && db) {
      var i2 = i;
      while (i2 < ra.length && _isDigit(ra.codeUnitAt(i2))) {
        i2++;
      }
      var j2 = j;
      while (j2 < rb.length && _isDigit(rb.codeUnitAt(j2))) {
        j2++;
      }
      final na = ra.substring(i, i2);
      final nb = rb.substring(j, j2);
      final va = BigInt.tryParse(na) ?? BigInt.zero;
      final vb = BigInt.tryParse(nb) ?? BigInt.zero;
      final byValue = va.compareTo(vb);
      if (byValue != 0) return byValue;
      if (na.length != nb.length) return na.length.compareTo(nb.length);
      i = i2;
      j = j2;
    } else {
      if (ca != cb) return ca.compareTo(cb);
      i++;
      j++;
    }
  }
  return (ra.length - i).compareTo(rb.length - j);
}

bool _isDigit(int code) => code >= 0x30 && code <= 0x39;
