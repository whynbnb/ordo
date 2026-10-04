import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import 'dialogs.dart';
import 'directory_picker.dart';
import 'job_progress.dart';

/// 存储分析：分类占用、最大文件、重复文件。
class AnalyzerScreen extends StatefulWidget {
  const AnalyzerScreen({super.key, this.initialRoot});

  final String? initialRoot;

  @override
  State<AnalyzerScreen> createState() => _AnalyzerScreenState();
}

class _AnalyzerScreenState extends State<AnalyzerScreen> {
  final OrdoService _service = OrdoService.instance;

  late String _root;
  AnalyzeResult? _result;

  @override
  void initState() {
    super.initState();
    _root = widget.initialRoot ?? '/storage/emulated/0';
  }

  Future<void> _pickRoot() async {
    final chosen = await pickDirectory(context, initial: _root);
    if (chosen != null) setState(() => _root = chosen);
  }

  Future<void> _run() async {
    try {
      final result = await runWithJobProgress<AnalyzeResult>(
        context,
        '正在分析',
        (jobId) => _service.analyze(_root, jobId: jobId),
      );
      if (!mounted) return;
      setState(() => _result = result);
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _cleanGroup(DuplicateGroup group) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除重复文件',
      message: '保留第一个，将其余 ${group.files.length - 1} 个移入回收站？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final paths = group.files.skip(1).map((file) => file.path).toList();
    try {
      final result = await _service.delete(paths, toTrash: true);
      _snack(
        result.trashed > 0 ? '已移入回收站 ${result.trashed} 个' : '删除失败',
        errors: result.errors,
      );
      await _run();
    } catch (error) {
      _snack('$error');
    }
  }

  void _snack(String message, {List<String> errors = const []}) {
    if (!mounted) return;
    final text = errors.isEmpty
        ? message
        : '$message\n${errors.take(3).join('\n')}';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  String _categoryLabel(String category) => switch (category) {
    'image' => '图片',
    'video' => '视频',
    'audio' => '音频',
    'document' => '文档',
    'archive' => '压缩包',
    'apk' => '安装包',
    'text' => '文本',
    _ => '其它',
  };

  IconData _categoryIcon(String category) => switch (category) {
    'image' => Icons.image_rounded,
    'video' => Icons.movie_rounded,
    'audio' => Icons.music_note_rounded,
    'document' => Icons.description_rounded,
    'archive' => Icons.folder_zip_rounded,
    'apk' => Icons.android_rounded,
    'text' => Icons.article_rounded,
    _ => Icons.insert_drive_file_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('存储分析'),
        actions: [
          IconButton(
            tooltip: '选择目录',
            icon: const Icon(Icons.folder_open_rounded),
            onPressed: _pickRoot,
          ),
          if (_result != null)
            IconButton(
              tooltip: '重新分析',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _run,
            ),
        ],
      ),
      body: _result == null ? _buildIntro(context) : _buildResult(context),
    );
  }

  Widget _buildIntro(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.pie_chart_outline_rounded,
              size: 56,
              color: scheme.primary,
            ),
            const SizedBox(height: 16),
            Text('分析存储占用', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '目录：$_root\n统计分类占用、最大文件与重复文件。',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.search_rounded),
              label: const Text('开始分析'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResult(BuildContext context) {
    final result = _result!;
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Card(
          elevation: 0,
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已用 ${formatBytes(result.totalSize)}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '${result.fileCount} 个文件 · ${result.dirCount} 个文件夹\n${result.root}',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        if (result.categories.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionTitle(context, '分类占用'),
          const SizedBox(height: 8),
          for (final stat in result.categories)
            _categoryRow(context, stat, result.totalSize),
        ],
        if (result.largest.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionTitle(context, '最大文件'),
          const SizedBox(height: 4),
          for (final file in result.largest) _fileTile(context, file),
        ],
        if (result.duplicates.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionTitle(context, '重复文件'),
          const SizedBox(height: 8),
          for (final group in result.duplicates) _duplicateCard(context, group),
        ],
        if (result.duplicates.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              '未发现重复文件。',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w600),
    );
  }

  Widget _categoryRow(BuildContext context, CategoryStat stat, int total) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = total > 0 ? stat.size / total : 0.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(_categoryIcon(stat.category), size: 20, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(_categoryLabel(stat.category))),
                    Text(
                      '${formatBytes(stat.size)} · ${stat.count}',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 6,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileTile(BuildContext context, AnalysisFile file) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(_categoryIcon(file.category), color: scheme.primary),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(file.path, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(formatBytes(file.size)),
    );
  }

  Widget _duplicateCard(BuildContext context, DuplicateGroup group) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${group.files.length} 个相同文件 · 每个 ${formatBytes(group.size)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: () => _cleanGroup(group),
                  child: Text('清理 ${formatBytes(group.reclaimable)}'),
                ),
              ],
            ),
            for (final file in group.files)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  file.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
