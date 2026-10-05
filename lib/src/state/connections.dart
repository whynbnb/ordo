import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../services/ordo_service.dart';

/// 远程连接配置的全局状态。
class ConnectionStore extends ChangeNotifier {
  ConnectionStore._();

  static final ConnectionStore instance = ConnectionStore._();

  final OrdoService _service = OrdoService.instance;

  List<ConnectionProfile> _profiles = const [];
  bool _loading = false;
  String? _error;

  List<ConnectionProfile> get profiles => _profiles;
  bool get loading => _loading;
  String? get error => _error;

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _profiles = await _service.profiles();
    } catch (error) {
      _error = '$error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<ConnectionProfile> save(ConnectionProfile profile) async {
    final saved = await _service.saveProfile(profile);
    final list = [..._profiles];
    final index = list.indexWhere((p) => p.id == saved.id);
    if (index >= 0) {
      list[index] = saved;
    } else {
      list.add(saved);
    }
    _profiles = list;
    notifyListeners();
    return saved;
  }

  Future<void> remove(ConnectionProfile profile) async {
    await _service.removeProfile(profile.id);
    _profiles = _profiles.where((p) => p.id != profile.id).toList();
    notifyListeners();
  }

  Future<void> disconnect(ConnectionProfile profile) async {
    await _service.disconnect(profile.id);
  }

  Future<void> test(ConnectionProfile profile) async {
    await _service.testProfile(profile);
  }

  /// 导出为 JSON 文本（包含密码，注意妥善保管）。
  String exportJson() {
    return const JsonEncoder.withIndent('  ').convert({
      'app': 'ordo',
      'version': 1,
      'profiles': [for (final profile in _profiles) profile.toJson()],
    });
  }

  /// 从 JSON 文本导入（为新连接生成新 ID），返回导入数量。
  Future<int> importJson(String text) async {
    final decoded = jsonDecode(text);
    final raw = decoded is Map ? decoded['profiles'] : decoded;
    if (raw is! List) {
      throw const FormatException('文件格式不正确');
    }
    var count = 0;
    for (final item in raw) {
      if (item is! Map) continue;
      final profile = ConnectionProfile.fromJson(
        item.cast<String, dynamic>(),
      );
      if (profile.host.trim().isEmpty) continue;
      await _service.saveProfile(profile.copyWith(id: ''));
      count++;
    }
    await load();
    return count;
  }
}
