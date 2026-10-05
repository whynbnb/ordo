import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'prefs_store.dart';

/// 浏览历史中的一步（路径 + 标题）。
class NavStep {
  const NavStep(this.path, this.title);

  final String path;
  final String title;

  Map<String, Object?> toJson() => {'path': path, 'title': title};

  static NavStep fromJson(Object? raw) {
    if (raw is Map) {
      final map = raw.cast<String, Object?>();
      return NavStep('${map['path'] ?? ''}', '${map['title'] ?? ''}');
    }
    return const NavStep('', '');
  }
}

/// 单个标签页的会话：当前目录及其浏览历史。
class TabSession {
  const TabSession({
    required this.path,
    required this.title,
    required this.history,
    required this.index,
  });

  final String path;
  final String title;
  final List<NavStep> history;
  final int index;

  Map<String, Object?> toJson() => {
    'path': path,
    'title': title,
    'index': index,
    'history': history.map((step) => step.toJson()).toList(),
  };

  static TabSession fromJson(Object? raw) {
    if (raw is! Map) {
      return const TabSession(path: '', title: '', history: [], index: 0);
    }
    final map = raw.cast<String, Object?>();
    final history =
        (map['history'] as List?)?.map(NavStep.fromJson).toList() ??
        const <NavStep>[];
    return TabSession(
      path: '${map['path'] ?? ''}',
      title: '${map['title'] ?? ''}',
      history: history,
      index: (map['index'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 一次浏览会话：若干标签页及当前激活的标签。
class BrowserSession {
  const BrowserSession({required this.tabs, required this.active});

  final List<TabSession> tabs;
  final int active;

  Map<String, Object?> toJson() => {
    'tabs': tabs.map((tab) => tab.toJson()).toList(),
    'active': active,
  };

  static BrowserSession? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, Object?>();
    final tabs =
        (map['tabs'] as List?)?.map(TabSession.fromJson).toList() ??
        const <TabSession>[];
    if (tabs.isEmpty) return null;
    return BrowserSession(
      tabs: tabs,
      active: (map['active'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 浏览会话记录。
///
/// 运行期间一直保留（回到首页不会清除），只有应用完全关闭才随之消失。
/// 是否跨启动保留由「记住上次会话」开关决定（默认关闭）。
class SessionStore extends ChangeNotifier {
  SessionStore._();

  static final SessionStore instance = SessionStore._();

  static const String _key = 'session';
  static const String _rememberKey = 'remember_session';

  BrowserSession? _session;
  bool _remember = false;
  bool _loaded = false;

  BrowserSession? get session => _session;

  /// 是否存在可用的会话（至少有一个非空路径的标签页）。
  bool get hasSession =>
      _session != null && _session!.tabs.any((tab) => tab.path.isNotEmpty);

  bool get remember => _remember;
  bool get loaded => _loaded;

  Future<void> load() async {
    await PrefsStore.instance.loadIfNeeded();
    _remember = PrefsStore.instance.value(_rememberKey) == '1';
    if (_remember) {
      final raw = PrefsStore.instance.value(_key);
      if (raw != null && raw.isNotEmpty) {
        try {
          _session = BrowserSession.fromJson(jsonDecode(raw));
        } catch (_) {
          _session = null;
        }
      }
    } else {
      // 默认不记忆：清理上次运行可能残留的数据。
      _session = null;
      await PrefsStore.instance.setValue(_key, null);
    }
    _loaded = true;
    notifyListeners();
  }

  /// 记录当前会话（回到首页时也会由浏览页写入）。
  void record(BrowserSession? session) {
    if (session != null && session.tabs.isEmpty) return;
    _session = session;
    _persist();
    notifyListeners();
  }

  /// 清除会话。
  Future<void> clear() async {
    _session = null;
    await PrefsStore.instance.setValue(_key, null);
    notifyListeners();
  }

  /// 设置是否跨启动记住会话。
  Future<void> setRemember(bool value) async {
    _remember = value;
    notifyListeners();
    await PrefsStore.instance.setValue(_rememberKey, value ? '1' : null);
    if (value) {
      _persist();
    } else {
      await PrefsStore.instance.setValue(_key, null);
    }
  }

  void _persist() {
    if (!_remember) return;
    final raw = _session == null ? null : jsonEncode(_session!.toJson());
    // 异步写入，不阻塞导航。
    PrefsStore.instance.setValue(_key, raw);
  }
}
