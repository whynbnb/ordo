import 'package:flutter/material.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import '../services/platform_service.dart';
import '../state/browser_controller.dart';
import '../state/settings.dart';
import '../state/transfer_clipboard.dart';
import 'dialogs.dart';
import 'entry_tile.dart';
import 'open_entry.dart';
import 'search_screen.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, required this.path, required this.title});

  final String path;
  final String title;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final OrdoService _service = OrdoService.instance;
  late final BrowserController _controller;

  @override
  void initState() {
    super.initState();
    _controller = BrowserController(initialPath: widget.path);
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_controller, TransferClipboard.instance]),
      builder: (context, _) {
        return Scaffold(
          appBar: _buildAppBar(context),
          body: RefreshIndicator(
            onRefresh: _controller.refresh,
            child: _buildBody(context),
          ),
          floatingActionButton: _controller.selectionMode
              ? null
              : FloatingActionButton.extended(
                  onPressed: _showCreateSheet,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('新建'),
                ),
          bottomNavigationBar: _buildBottomBar(context),
        );
      },
    );
  }

  AppBar _buildAppBar(BuildContext context) {
    if (_controller.selectionMode) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _controller.clearSelection,
        ),
        title: Text('已选择 ${_controller.selectedCount} 项'),
        actions: [
          IconButton(
            tooltip: '全选',
            icon: const Icon(Icons.select_all_rounded),
            onPressed: _controller.selectAll,
          ),
        ],
      );
    }

    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            widget.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: '搜索',
          icon: const Icon(Icons.search_rounded),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  SearchScreen(root: widget.path, title: widget.title),
            ),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: _onMenuSelected,
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'refresh', child: Text('刷新')),
            PopupMenuItem(
              value: 'hidden',
              child: Row(
                children: [
                  if (_controller.showHidden)
                    const Icon(Icons.check_rounded, size: 18)
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 8),
                  const Text('显示隐藏文件'),
                ],
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'folder', child: Text('新建文件夹')),
            const PopupMenuItem(value: 'file', child: Text('新建文件')),
            PopupMenuItem(
              value: 'paste',
              enabled: !TransferClipboard.instance.isEmpty,
              child: Text('粘贴到此处 (${TransferClipboard.instance.count})'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'sort', child: Text('排序方式')),
          ],
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_controller.loading && _controller.entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_controller.error != null) {
      return ListView(
        children: [
          const SizedBox(height: 96),
          Icon(
            Icons.lock_outline_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _controller.error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: FilledButton.tonal(
              onPressed: _controller.refresh,
              child: const Text('重试'),
            ),
          ),
        ],
      );
    }

    final entries = _controller.entries;
    if (entries.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Icon(
            Icons.folder_open_rounded,
            size: 56,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              '空文件夹',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return EntryTile(
          entry: entry,
          selectionMode: _controller.selectionMode,
          selected: _controller.isSelected(entry.path),
          onTap: () => _controller.selectionMode
              ? _controller.toggleSelected(entry.path)
              : _openEntry(entry),
          onLongPress: () => _controller.toggleSelected(entry.path),
          onMenu: () => _showEntrySheet(entry),
        );
      },
    );
  }

  Widget? _buildBottomBar(BuildContext context) {
    if (_controller.selectionMode) {
      return BottomAppBar(
        height: 64,
        padding: EdgeInsets.zero,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _BarAction(
              icon: Icons.ios_share_rounded,
              label: '复制',
              onTap: () => _copySelection(move: false),
            ),
            _BarAction(
              icon: Icons.drive_file_move_rounded,
              label: '移动',
              onTap: () => _copySelection(move: true),
            ),
            _BarAction(
              icon: Icons.delete_outline_rounded,
              label: '删除',
              onTap: _deleteSelection,
            ),
            _BarAction(
              icon: Icons.more_horiz_rounded,
              label: '更多',
              onTap: _showSelectionSheet,
            ),
          ],
        ),
      );
    }

    final clipboard = TransferClipboard.instance;
    if (!clipboard.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      return Material(
        color: scheme.surfaceContainerHighest,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  clipboard.isMove
                      ? Icons.drive_file_move_rounded
                      : Icons.copy_rounded,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '已${clipboard.isMove ? '剪切' : '复制'} ${clipboard.count} 项',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(onPressed: clipboard.clear, child: const Text('取消')),
                const SizedBox(width: 4),
                FilledButton(onPressed: _paste, child: const Text('粘贴')),
              ],
            ),
          ),
        ),
      );
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // 行为
  // -------------------------------------------------------------------------

  Future<void> _openEntry(FileEntry entry) async {
    await openEntry(context, entry, onReturn: _controller.refresh);
  }

  void _onMenuSelected(String value) {
    switch (value) {
      case 'refresh':
        _controller.refresh();
      case 'hidden':
        _controller.setShowHidden(!_controller.showHidden);
      case 'folder':
        _create(folder: true);
      case 'file':
        _create(folder: false);
      case 'paste':
        _paste();
      case 'sort':
        _showSortSheet();
    }
  }

  Future<void> _create({required bool folder}) async {
    final name = await showNameDialog(
      context,
      title: folder ? '新建文件夹' : '新建文件',
      hintText: folder ? '文件夹名称' : '文件名',
      confirmLabel: '创建',
    );
    if (name == null || name.isEmpty || !mounted) return;
    final path = joinPath(_controller.path, name);
    try {
      if (folder) {
        await _service.createDir(path);
      } else {
        await _service.createFile(path);
      }
      await _controller.refresh();
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _rename(FileEntry entry) async {
    final name = await showNameDialog(
      context,
      title: '重命名',
      initialText: entry.name,
    );
    if (name == null || name.isEmpty || name == entry.name || !mounted) return;
    try {
      await _service.rename(entry.path, name);
      _controller.clearSelection();
      await _controller.refresh();
    } catch (error) {
      _snack('$error');
    }
  }

  void _copySelection({required bool move}) {
    final paths = _controller.selectedEntries.map((e) => e.path).toList();
    if (paths.isEmpty) return;
    TransferClipboard.instance.set(paths, move: move);
    _controller.clearSelection();
    _snack('已${move ? '剪切' : '复制'} ${paths.length} 项');
  }

  Future<void> _deleteSelection() async {
    final paths = _controller.selectedPaths.toList();
    await _delete(paths);
  }

  Future<void> _delete(List<String> paths) async {
    if (paths.isEmpty) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '删除',
      message: '确定删除选中的 ${paths.length} 项吗？此操作无法撤销。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      final result = await _service.delete(paths);
      _controller.clearSelection();
      await _controller.refresh();
      _snack(
        result.deleted > 0 ? '已删除 ${result.deleted} 项' : '删除失败',
        errors: result.errors,
      );
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _paste() async {
    final clipboard = TransferClipboard.instance;
    if (clipboard.isEmpty) return;
    final paths = clipboard.paths;
    final move = clipboard.isMove;
    try {
      final result = move
          ? await _service.move(paths, _controller.path)
          : await _service.copy(paths, _controller.path);
      clipboard.clear();
      await _controller.refresh();
      _snack(
        result.done > 0 ? '已${move ? '移动' : '复制'} ${result.done} 项' : '操作失败',
        errors: result.errors,
      );
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _share(FileEntry entry) async {
    if (entry.isDir) {
      _snack('暂不支持分享文件夹');
      return;
    }
    final ok = await PlatformService.shareFile(
      entry.path,
      mime: mimeOfExtension(entry.extension),
    );
    if (!ok) _snack('分享失败');
  }

  // -------------------------------------------------------------------------
  // 面板
  // -------------------------------------------------------------------------

  Future<void> _showCreateSheet() async {
    final clipboard = TransferClipboard.instance;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.create_new_folder_rounded),
                title: const Text('新建文件夹'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _create(folder: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.note_add_rounded),
                title: const Text('新建文件'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _create(folder: false);
                },
              ),
              if (!clipboard.isEmpty)
                ListTile(
                  leading: const Icon(Icons.content_paste_rounded),
                  title: Text('粘贴 (${clipboard.count} 项)'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _paste();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showSortSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final field in SortField.values)
                ListTile(
                  leading: Icon(
                    _controller.sortField == field
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                  ),
                  title: Text(field.label),
                  onTap: () {
                    _controller.setSortField(field);
                    Navigator.pop(sheetContext);
                  },
                ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  _controller.sortAscending
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                ),
                title: Text(_controller.sortAscending ? '升序' : '降序'),
                onTap: () {
                  _controller.setSortField(_controller.sortField);
                  Navigator.pop(sheetContext);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showEntrySheet(FileEntry entry) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  entry.isDir
                      ? Icons.folder_open_rounded
                      : Icons.open_in_new_rounded,
                ),
                title: Text(entry.isDir ? '打开' : '打开方式'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openEntry(entry);
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline_rounded),
                title: const Text('重命名'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _rename(entry);
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  TransferClipboard.instance.set([entry.path], move: false);
                  _snack('已复制到剪贴板');
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_rounded),
                title: const Text('移动'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  TransferClipboard.instance.set([entry.path], move: true);
                  _snack('已剪切到剪贴板');
                },
              ),
              if (!entry.isDir)
                ListTile(
                  leading: const Icon(Icons.ios_share_rounded),
                  title: const Text('分享'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _share(entry);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('详细信息'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  showDetailsSheet(context, entry);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
                title: Text(
                  '删除',
                  style: TextStyle(
                    color: Theme.of(sheetContext).colorScheme.error,
                  ),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _delete([entry.path]);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showSelectionSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline_rounded),
                title: const Text('重命名'),
                enabled: _controller.singleSelected != null,
                onTap: () {
                  final entry = _controller.singleSelected;
                  Navigator.pop(sheetContext);
                  if (entry != null) _rename(entry);
                },
              ),
              ListTile(
                leading: const Icon(Icons.ios_share_rounded),
                title: const Text('分享'),
                enabled:
                    _controller.singleSelected != null &&
                    !_controller.singleSelected!.isDir,
                onTap: () {
                  final entry = _controller.singleSelected;
                  Navigator.pop(sheetContext);
                  if (entry != null) _share(entry);
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('详细信息'),
                enabled: _controller.singleSelected != null,
                onTap: () {
                  final entry = _controller.singleSelected;
                  Navigator.pop(sheetContext);
                  if (entry != null) showDetailsSheet(context, entry);
                },
              ),
            ],
          ),
        );
      },
    );
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
}

class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 2),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}
