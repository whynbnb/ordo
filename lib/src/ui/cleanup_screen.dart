import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';

/// 智能清理：分类列出可安全删除的垃圾文件，一键清理。
class CleanupScreen extends StatefulWidget {
  const CleanupScreen({super.key, required this.root, required this.title});

  final String root;
  final String title;

  @override
  State<CleanupScreen> createState() => _CleanupScreenState();
}

class _CleanupScreenState extends State<CleanupScreen> {
  final OrdoService _service = OrdoService.instance;

  CleanupResult? _result;
  bool _busy = true;
  String? _error;
  bool _temp = true;
  bool _emptyFiles = true;
  bool _emptyDirs = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _service.cleanupScan(widget.root);
      if (!mounted) return;
      setState(() {
        _result = result;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  List<String> _selectedPaths(CleanupResult result) {
    final paths = <String>[];
    if (_temp) paths.addAll(result.tempFiles.map((e) => e.path));
    if (_emptyFiles) paths.addAll(result.emptyFiles.map((e) => e.path));
    if (_emptyDirs) paths.addAll(result.emptyDirs.map((e) => e.path));
    return paths;
  }

  Future<void> _clean() async {
    final result = _result;
    if (result == null) return;
    final paths = _selectedPaths(result);
    if (paths.isEmpty) {
      _snack('没有可清理的项目');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清理垃圾文件'),
        content: Text('将永久删除 ${paths.length} 个项目，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final deleted = await _service.delete(paths, toTrash: false);
      if (!mounted) return;
      _snack(
        deleted.errors.isEmpty
            ? '已清理 ${deleted.deleted} 项'
            : '已清理 ${deleted.deleted} 项，${deleted.errors.length} 项失败',
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('清理失败：$error');
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
    final result = _result;
    final selectedCount = result == null ? 0 : _selectedPaths(result).length;

    return Scaffold(
      appBar: AppBar(
        title: Text('清理「${widget.title}」'),
        actions: [
          IconButton(
            tooltip: '重新扫描',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _busy && result == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : result == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _summary(context, result),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('临时 / 缓存文件（${result.tempFiles.length}）'),
                  subtitle: Text(
                    result.tempFiles.isEmpty
                        ? '无'
                        : formatBytes(
                            result.tempFiles.fold<int>(
                              0,
                              (sum, e) => sum + e.size,
                            ),
                          ),
                  ),
                  value: _temp,
                  onChanged: (value) => setState(() => _temp = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('空文件（${result.emptyFiles.length}）'),
                  value: _emptyFiles,
                  onChanged: (value) => setState(() => _emptyFiles = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('空文件夹（${result.emptyDirs.length}）'),
                  value: _emptyDirs,
                  onChanged: (value) => setState(() => _emptyDirs = value),
                ),
                if (result.truncated)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '结果过多，已截断显示',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy || selectedCount == 0 ? null : _clean,
                  icon: const Icon(Icons.delete_sweep_rounded),
                  label: Text('清理所选（$selectedCount 项）'),
                ),
                const SizedBox(height: 8),
                Text(
                  '清理会永久删除文件，请确认后再操作。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _summary(BuildContext context, CleanupResult result) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.primaryContainer.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '发现 ${result.total} 个可清理项目',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text('可释放约 ${formatBytes(result.reclaimable)}'),
            const SizedBox(height: 4),
            Text(
              '已扫描 ${result.scanned} 个条目',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
