import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'prefs_store.dart';

/// 首页工具项定义。
class HomeTool {
  const HomeTool(this.id, this.title, this.subtitle);

  final String id;

  /// 中文原文字典 key，显示时用 `tr(title)` 翻译。
  final String title;
  final String subtitle;
}

List<HomeTool> get homeTools => [
  HomeTool('recent', '最近访问', '最近打开的文件与文件夹'),
  HomeTool('trash', '回收站', '查看与恢复已删除的文件'),
  HomeTool('analyzer', '存储分析', '分类占用、大文件与重复文件'),
  HomeTool('cleanup', '智能清理', '空文件、空文件夹、临时 / 缓存文件'),
  HomeTool('trend', '存储趋势', '定期记录并比较目录用量变化'),
  HomeTool('vault', '隐私空间', '把文件移入应用私有目录隐藏'),
];

/// 首页「常用」目录候选（按存储根下的目录名匹配）。
const List<String> homeQuickCandidates = [
  'Download',
  'Pictures',
  'DCIM',
  'Music',
  'Movies',
  'Documents',
];

/// 首页布局：工具顺序 / 显隐、常用目录顺序 / 显隐。
class HomeLayoutStore extends ChangeNotifier {
  HomeLayoutStore._();

  static final HomeLayoutStore instance = HomeLayoutStore._();

  List<String> _tools = [for (final tool in homeTools) tool.id];
  List<String> _quick = List.of(homeQuickCandidates);
  bool _loaded = false;

  List<String> get tools => _tools;
  List<String> get quick => _quick;

  Future<void> loadIfNeeded() async {
    if (_loaded) return;
    await PrefsStore.instance.loadIfNeeded();
    _tools = _decode(PrefsStore.instance.value('home_tools'), _defaultTools());
    _quick = _decode(
      PrefsStore.instance.value('home_quick'),
      List.of(homeQuickCandidates),
    );
    _loaded = true;
    notifyListeners();
  }

  List<String> _defaultTools() => [for (final tool in homeTools) tool.id];

  List<String> _decode(String? raw, List<String> fallback) {
    if (raw == null || raw.isEmpty) return fallback;
    try {
      final list = (jsonDecode(raw) as List).map((e) => e.toString()).toList();
      return list;
    } catch (_) {
      return fallback;
    }
  }

  Future<void> setTools(List<String> tools) async {
    _tools = tools;
    notifyListeners();
    await PrefsStore.instance.setValue('home_tools', jsonEncode(tools));
  }

  Future<void> setQuick(List<String> quick) async {
    _quick = quick;
    notifyListeners();
    await PrefsStore.instance.setValue('home_quick', jsonEncode(quick));
  }

  Future<void> reset() async {
    _tools = _defaultTools();
    _quick = List.of(homeQuickCandidates);
    notifyListeners();
    await PrefsStore.instance.setValue('home_tools', null);
    await PrefsStore.instance.setValue('home_quick', null);
  }
}
