import 'package:flutter/material.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import '../services/platform_service.dart';
import 'browser_screen.dart';
import 'dialogs.dart';
import 'directory_picker.dart';
import 'job_progress.dart';
import 'open_entry.dart';

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

  // -------------------------------------------------------------------------
  // 大文件操作：打开 / 打开所在位置 / 分享 / 删除
  // -------------------------------------------------------------------------

  Future<void> _showFileActions(AnalysisFile file) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(_categoryIcon(file.category), color: scheme.primary),
                title: Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(formatBytes(file.size)),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: const Text('打开'),
                onTap: () => Navigator.pop(sheetContext, 'open'),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('打开所在文件夹'),
                onTap: () => Navigator.pop(sheetContext, 'folder'),
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('分享'),
                onTap: () => Navigator.pop(sheetContext, 'share'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('移入回收站'),
                onTap: () => Navigator.pop(sheetContext, 'trash'),
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_forever_outlined,
                  color: scheme.error,
                ),
                title: Text('永久删除', style: TextStyle(color: scheme.error)),
                onTap: () => Navigator.pop(sheetContext, 'delete'),
              ),
            ],
          ),
        );
      },
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'open':
        await _openFile(file);
      case 'folder':
        await _openFolder(file);
      case 'share':
        await _shareFile(file);
      case 'trash':
        await _deleteFile(file, toTrash: true);
      case 'delete':
        await _deleteFile(file, toTrash: false);
    }
  }

  Future<void> _openFile(AnalysisFile file) async {
    final entry = FileEntry(
      name: file.name,
      path: file.path,
      isDir: false,
      isSymlink: false,
      hidden: false,
      size: file.size,
      modified: 0,
      created: 0,
      extension: _extensionOf(file.name),
      readable: true,
      writable: true,
    );
    await openEntry(context, entry);
  }

  Future<void> _openFolder(AnalysisFile file) async {
    final parent = parentOf(file.path);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(path: parent, title: baseName(parent)),
      ),
    );
    if (mounted) await _run();
  }

  Future<void> _shareFile(AnalysisFile file) async {
    final ok = await PlatformService.shareFile(
      file.path,
      mime: mimeOfExtension(_extensionOf(file.name)),
    );
    if (!ok && mounted) _snack('没有可以分享此文件的应用');
  }

  Future<void> _deleteFile(AnalysisFile file, {required bool toTrash}) async {
    final confirmed = await showConfirmDialog(
      context,
      title: toTrash ? '移入回收站' : '永久删除',
      message: toTrash
          ? '将「${file.name}」移入回收站？可在「回收站」中恢复。'
          : '永久删除「${file.name}」？此操作不可恢复。',
      confirmLabel: toTrash ? '移入回收站' : '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      final result = await _service.delete([file.path], toTrash: toTrash);
      final parts = <String>[];
      if (result.trashed > 0) parts.add('已移入回收站');
      if (result.deleted > 0) parts.add('已永久删除');
      _snack(parts.isEmpty ? '删除失败' : parts.join('，'), errors: result.errors);
      await _run();
    } catch (error) {
      _snack('$error');
    }
  }

  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1);
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
          Text(
            '点击文件可打开、分享或删除',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
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
      onTap: () => _showFileActions(file),
      leading: Icon(_categoryIcon(file.category), color: scheme.primary),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(file.path, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatBytes(file.size),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 4),
          Icon(Icons.more_vert_rounded, size: 18, color: scheme.outline),
        ],
      ),
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
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: VisualDensity.compact,
                onTap: () => _showFileActions(file),
                title: Text(
                  file.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                trailing: Icon(
                  Icons.more_vert_rounded,
                  size: 18,
                  color: scheme.outline,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
