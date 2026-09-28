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
}
