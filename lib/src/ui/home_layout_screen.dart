import 'package:flutter/material.dart';

import '../state/home_layout.dart';

const Map<String, String> _quickLabels = {
  'Download': '下载',
  'Pictures': '图片',
  'DCIM': '相机',
  'Music': '音乐',
  'Movies': '视频',
  'Documents': '文档',
};

/// 首页布局：调整工具与「常用」目录的顺序与显隐。
class HomeLayoutScreen extends StatefulWidget {
  const HomeLayoutScreen({super.key});

  @override
  State<HomeLayoutScreen> createState() => _HomeLayoutScreenState();
}

class _HomeLayoutScreenState extends State<HomeLayoutScreen> {
  final HomeLayoutStore _store = HomeLayoutStore.instance;

  late List<String> _toolOrder;
  late Set<String> _visibleTools;
  late List<String> _quickOrder;
  late Set<String> _visibleQuick;

  @override
  void initState() {
    super.initState();
    final allTools = [for (final tool in homeTools) tool.id];
    final visibleTools = _store.tools;
    _toolOrder = [
      ...visibleTools,
      ...allTools.where((id) => !visibleTools.contains(id)),
    ];
    _visibleTools = visibleTools.toSet();

    final visibleQuick = _store.quick;
    _quickOrder = [
      ...visibleQuick,
      ...homeQuickCandidates.where((id) => !visibleQuick.contains(id)),
    ];
    _visibleQuick = visibleQuick.toSet();
  }

  void _saveTools() {
    _store.setTools(
      _toolOrder.where((id) => _visibleTools.contains(id)).toList(),
    );
  }

  void _saveQuick() {
    _store.setQuick(
      _quickOrder.where((id) => _visibleQuick.contains(id)).toList(),
    );
  }

  void _move(List<String> order, int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= order.length) return;
    setState(() {
      final item = order.removeAt(index);
      order.insert(target, item);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('首页布局'),
        actions: [
          TextButton(
            onPressed: () async {
              await _store.reset();
              if (!mounted) return;
              setState(() {
                _toolOrder = [for (final tool in homeTools) tool.id];
                _visibleTools = _toolOrder.toSet();
                _quickOrder = List.of(homeQuickCandidates);
                _visibleQuick = _quickOrder.toSet();
              });
            },
            child: const Text('重置'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _header('工具'),
          for (var i = 0; i < _toolOrder.length; i++) _toolRow(i),
          const SizedBox(height: 24),
          _header('常用目录'),
          for (var i = 0; i < _quickOrder.length; i++) _quickRow(i),
        ],
      ),
    );
  }

  Widget _header(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _toolRow(int index) {
    final id = _toolOrder[index];
    final tool = homeTools.firstWhere((t) => t.id == id);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: ListTile(
        leading: Switch(
          value: _visibleTools.contains(id),
          onChanged: (value) {
            setState(() {
              if (value) {
                _visibleTools.add(id);
              } else {
                _visibleTools.remove(id);
              }
            });
            _saveTools();
          },
        ),
        title: Text(tool.title),
        subtitle: Text(tool.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: _moveButtons(
          index,
          _toolOrder.length,
          (delta) {
            _move(_toolOrder, index, delta);
            _saveTools();
          },
        ),
      ),
    );
  }

  Widget _quickRow(int index) {
    final id = _quickOrder[index];
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: ListTile(
        leading: Switch(
          value: _visibleQuick.contains(id),
          onChanged: (value) {
            setState(() {
              if (value) {
                _visibleQuick.add(id);
              } else {
                _visibleQuick.remove(id);
              }
            });
            _saveQuick();
          },
        ),
        title: Text(_quickLabels[id] ?? id),
        trailing: _moveButtons(index, _quickOrder.length, (delta) {
          _move(_quickOrder, index, delta);
          _saveQuick();
        }),
      ),
    );
  }

  Widget _moveButtons(int index, int length, void Function(int delta) onMove) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '上移',
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
          onPressed: index == 0 ? null : () => onMove(-1),
        ),
        IconButton(
          tooltip: '下移',
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: index == length - 1 ? null : () => onMove(1),
        ),
      ],
    );
  }
}
