import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import 'directory_picker.dart';

/// 崩溃 / 错误日志查看与导出。
class CrashLogScreen extends StatefulWidget {
  const CrashLogScreen({super.key});

  @override
  State<CrashLogScreen> createState() => _CrashLogScreenState();
}

class _CrashLogScreenState extends State<CrashLogScreen> {
  final OrdoService _service = OrdoService.instance;

  CrashLog _log = CrashLog.empty;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final log = await _service.crashRead();
      if (!mounted) return;
      setState(() {
        _log = log;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    if (_log.text.isEmpty) {
      _snack('暂无日志可导出');
      return;
    }
    final dir = await pickDirectory(
      context,
      initial: '/storage/emulated/0/Download',
    );
    if (dir == null || !mounted) return;
    final path = joinPath(dir, 'ordo_crash.log');
    try {
      await _service.writeText(path, _log.text);
      _snack('已导出到 $path');
    } catch (error) {
      _snack('导出失败：$error');
    }
  }

  Future<void> _clear() async {
    try {
      await _service.crashClear();
      await _load();
      _snack('已清空日志');
    } catch (error) {
      _snack('清空失败：$error');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('崩溃日志'),
        actions: [
          IconButton(
            tooltip: '导出',
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.ios_share_rounded),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: _busy ? null : _clear,
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _log.text.isEmpty
          ? const Center(child: Text('暂无日志'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '共 ${_log.lines} 行 · ${_log.path}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SelectableText(
                  _log.text,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ],
            ),
    );
  }
}
