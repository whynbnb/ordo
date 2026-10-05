import 'package:flutter/material.dart';

import '../core/breadcrumbs.dart';
import '../core/file_types.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import '../services/platform_service.dart';
import '../state/browser_controller.dart';
import '../state/drop_controller.dart';
import '../state/favorites.dart';
import '../state/recent_store.dart';
import '../state/route_observer.dart';
import '../state/settings.dart';
import '../state/transfer_clipboard.dart';
import 'dialogs.dart';
import 'drop_overlay.dart';
import 'entry_tile.dart';
import 'job_progress.dart';
import 'open_entry.dart';
import 'path_breadcrumb.dart';
import 'search_screen.dart';
import 'zip_viewer.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, required this.path, required this.title});

  final String path;
  final String title;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with RouteAware, WidgetsBindingObserver {
  final OrdoService _service = OrdoService.instance;
  late final BrowserController _controller;

  /// 当前目录（支持在同一个页面内前进 / 后退，而不是层层压栈）。
  late String _path;
  late String _title;

  /// 浏览历史与游标。
  final List<_NavStep> _history = [];
  int _historyIndex = -1;

  bool get _canGoBack => _historyIndex > 0;
  bool get _canGoForward => _historyIndex < _history.length - 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _path = widget.path;
    _title = widget.title;
    _history.add(_NavStep(_path, _title));
    _historyIndex = 0;
    _controller = BrowserController(initialPath: _path);
    _controller.load();
    DropController.instance.revision.addListener(_onDropRevision);
    FavoritesStore.instance.loadIfNeeded();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      ordoRouteObserver.subscribe(this, route);
      if (route.isCurrent) _updateDropTarget();
    }
  }

  @override
  void dispose() {
    ordoRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    DropController.instance.revision.removeListener(_onDropRevision);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 恢复前台时重新声明拖放目标，确保跨应用拖入落在当前浏览的目录。
    if (state == AppLifecycleState.resumed) _updateDropTarget();
  }

  @override
  void didPush() => _updateDropTarget();

  @override
  void didPopNext() => _updateDropTarget();

  void _updateDropTarget() {
    // 栈中可能同时存在多个浏览页，只有当前可见的那个才设置目标。
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    DropController.instance.setActive(_path, _title);
  }

  /// 在当前页面内进入新目录，并写入历史。
  Future<void> _navigateToPath(String path, String title) async {
    if (path == _path) return;
    setState(() {
      _path = path;
      _title = title;
      _history.removeRange(_historyIndex + 1, _history.length);
      _history.add(_NavStep(path, title));
      _historyIndex = _history.length - 1;
    });
    RecentStore.instance.record(path, title, true);
    await _controller.navigateTo(path);
    if (mounted) _updateDropTarget();
  }

  /// 前进 / 后退到历史中的某一步。
  void _goHistory(int index) {
    if (index < 0 || index >= _history.length || index == _historyIndex) return;
    final step = _history[index];
    setState(() {
      _historyIndex = index;
      _path = step.path;
      _title = step.title;
    });
    _controller.navigateTo(step.path);
    _updateDropTarget();
  }

  void _handleBack() {
    if (_canGoBack) {
      _goHistory(_historyIndex - 1);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _onDropRevision() {
    if (mounted) _controller.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _controller,
        TransferClipboard.instance,
        FavoritesStore.instance,
      ]),
      builder: (context, _) {
        return PopScope(
          canPop: !_canGoBack,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && _canGoBack) _goHistory(_historyIndex - 1);
          },
          child: Scaffold(
            appBar: _buildAppBar(context),
            body: Stack(
              children: [
                RefreshIndicator(
                  onRefresh: _controller.refresh,
                  child: _buildBody(context),
                ),
                const DropOverlay(),
              ],
            ),
            floatingActionButton: _controller.selectionMode
                ? null
                : FloatingActionButton.extended(
                    onPressed: _showCreateSheet,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('新建'),
                  ),
            bottomNavigationBar: _buildBottomBar(context),
          ),
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
      automaticallyImplyLeading: false,
      leadingWidth: 96,
      leading: Row(
        children: [
          IconButton(
            tooltip: '后退',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: _handleBack,
          ),
          IconButton(
            tooltip: '前进',
            icon: const Icon(Icons.arrow_forward_rounded),
            onPressed: _canGoForward
                ? () => _goHistory(_historyIndex + 1)
                : null,
          ),
        ],
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          PathBreadcrumb(path: _path, onNavigate: _navigateTo),
        ],
      ),
      actions: [
        IconButton(
          tooltip: _isFavorite ? '取消收藏' : '收藏',
          icon: Icon(
            _isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
          ),
          onPressed: _toggleFavorite,
        ),
        IconButton(
          tooltip: '搜索',
          icon: const Icon(Icons.search_rounded),
          onPressed: _openSearch,
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
    if (entry.isDir) {
      await _navigateToPath(entry.path, entry.name);
      return;
    }
    await openEntry(context, entry, onReturn: _controller.refresh);
  }

  bool get _isFavorite => FavoritesStore.instance.contains(_path);

  Future<void> _toggleFavorite() async {
    try {
      if (_isFavorite) {
        await FavoritesStore.instance.remove(_path);
        _snack('已取消收藏');
      } else {
        await FavoritesStore.instance.add(_title, _path);
        _snack('已收藏「$_title」');
      }
    } catch (error) {
      _snack('$error');
    }
  }

  void _navigateTo(PathCrumb crumb) {
    _navigateToPath(crumb.path, crumb.label);
  }

  void _openSearch() {
    if (isRemotePath(_path)) {
      _snack('网络位置暂不支持搜索');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchScreen(root: _path, title: _title),
      ),
    );
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

  String _stem(String path) {
    final base = path.replaceAll(RegExp(r'/+$'), '').split('/').last;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  Future<void> _zipCompress(List<String> paths) async {
    if (paths.isEmpty) return;
    final defaultName = paths.length == 1
        ? '${_stem(paths.first)}.zip'
        : '${_title.isEmpty ? 'archive' : _title}.zip';
    final name = await showNameDialog(
      context,
      title: '压缩为 ZIP',
      initialText: defaultName,
      confirmLabel: '压缩',
    );
    if (name == null || name.isEmpty || !mounted) return;
    final fileName = name.toLowerCase().endsWith('.zip') ? name : '$name.zip';
    final dest = joinPath(_controller.path, fileName);
    try {
      await runWithJobProgress<void>(
        context,
        '正在压缩',
        (jobId) => _service.zipCreate(paths, dest, jobId: jobId),
      );
      await _controller.refresh();
      _snack('已创建「$fileName」');
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _zipExtract(FileEntry entry) async {
    final folder = _stem(entry.name);
    final dest = joinPath(_controller.path, folder);
    try {
      await runWithJobProgress<void>(
        context,
        '正在解压',
        (jobId) => _service.zipExtract(entry.path, dest, jobId: jobId),
      );
      await _controller.refresh();
      _snack('已解压到「$folder」');
    } catch (error) {
      _snack('$error');
    }
  }

  void _openZip(FileEntry entry) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) =>
                ZipViewerScreen(entry: entry, parentDir: _controller.path),
          ),
        )
        .then((_) {
          if (mounted) _controller.refresh();
        });
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
    final allowTrash = paths.every((path) => !isRemotePath(path));
    final toTrash = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: const Text('删除'),
          content: Text(
            allowTrash
                ? '确定删除选中的 ${paths.length} 项吗？\n移入回收站后可在「回收站」中恢复。'
                : '确定删除选中的 ${paths.length} 项吗？\n网络位置不支持回收站，将永久删除。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text('永久删除', style: TextStyle(color: scheme.error)),
            ),
            if (allowTrash)
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('移入回收站'),
              ),
          ],
        );
      },
    );
    if (toTrash == null || !mounted) return;
    try {
      final result = await _service.delete(paths, toTrash: toTrash);
      _controller.clearSelection();
      await _controller.refresh();
      final parts = <String>[];
      if (result.trashed > 0) parts.add('移入回收站 ${result.trashed} 项');
      if (result.deleted > 0) parts.add('永久删除 ${result.deleted} 项');
      _snack(parts.isEmpty ? '删除失败' : parts.join('，'), errors: result.errors);
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
      final result = await runWithJobProgress<TransferResult>(
        context,
        move ? '正在移动' : '正在复制',
        (jobId) => move
            ? _service.move(paths, _controller.path, jobId: jobId)
            : _service.copy(paths, _controller.path, jobId: jobId),
      );
      if (!mounted) return;
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
                leading: const Icon(Icons.archive_outlined),
                title: const Text('压缩为 ZIP'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _zipCompress([entry.path]);
                },
              ),
              if (entry.extension == 'zip') ...[
                ListTile(
                  leading: const Icon(Icons.unarchive_outlined),
                  title: const Text('解压到此处'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _zipExtract(entry);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.list_alt_rounded),
                  title: const Text('查看压缩包内容'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openZip(entry);
                  },
                ),
              ],
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
                leading: const Icon(Icons.archive_outlined),
                title: const Text('压缩为 ZIP'),
                onTap: () {
                  final paths = _controller.selectedEntries
                      .map((e) => e.path)
                      .toList();
                  Navigator.pop(sheetContext);
                  _zipCompress(paths);
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

/// 浏览历史中的一步。
class _NavStep {
  const _NavStep(this.path, this.title);

  final String path;
  final String title;
}
