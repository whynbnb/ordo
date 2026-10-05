import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/breadcrumbs.dart';
import '../core/file_types.dart';
import '../core/format.dart';
import '../core/labels.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import '../services/platform_service.dart';
import '../state/browser_controller.dart';
import '../state/drop_controller.dart';
import '../state/favorites.dart';
import '../state/label_store.dart';
import '../state/recent_store.dart';
import '../state/route_observer.dart';
import '../state/session_store.dart';
import '../state/settings.dart';
import '../state/transfer_clipboard.dart';
import '../state/transfer_queue.dart';
import '../state/view_store.dart';
import 'archive_actions.dart';
import 'archive_viewer.dart';
import 'dialogs.dart';
import 'drop_overlay.dart';
import 'entry_tile.dart';
import 'job_progress.dart';
import 'open_entry.dart';
import 'path_breadcrumb.dart';
import 'search_screen.dart';
import 'transfer_screen.dart';
import 'viewer_screen.dart';
import '../i18n/i18n.dart';
import 'snack.dart';

/// 供父级（标签页容器）控制 / 观察单个浏览页的返回能力与会话状态。
class BrowserScreenController extends ChangeNotifier {
  bool _canGoBack = false;
  TabSession? _state;
  VoidCallback? _back;

  bool get canGoBack => _canGoBack;
  TabSession? get state => _state;

  void _attach(VoidCallback back) => _back = back;
  void _detach() => _back = null;

  /// 触发该浏览页后退（先走页内历史，再交给外层）。
  void goBack() => _back?.call();

  void _update(bool canGoBack, TabSession state) {
    _canGoBack = canGoBack;
    _state = state;
    notifyListeners();
  }
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({
    super.key,
    required this.path,
    required this.title,
    this.onLocationChanged,
    this.controller,
    this.onExit,
    this.initialHistory,
    this.initialIndex = 0,
  });

  final String path;
  final String title;

  /// 当前目录变化时回调（用于标签页标题等）。
  final void Function(String path, String title)? onLocationChanged;

  /// 由标签页容器注入，用于返回与会话记录；独立使用时为 null。
  final BrowserScreenController? controller;

  /// 页内历史已到尽头时，返回按钮的落点（标签页里是「回到首页」）。
  final VoidCallback? onExit;

  /// 从会话恢复时的历史与游标。
  final List<NavStep>? initialHistory;
  final int initialIndex;

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
  final List<NavStep> _history = [];
  int _historyIndex = -1;

  /// 文件列表滚动位置（用于返回时恢复）。
  final ScrollController _scroll = ScrollController();

  bool get _canGoBack => _historyIndex > 0;
  bool get _canGoForward => _historyIndex < _history.length - 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final restore = widget.initialHistory;
    if (restore != null && restore.isNotEmpty) {
      _history.addAll(restore);
      _historyIndex = widget.initialIndex.clamp(0, restore.length - 1).toInt();
      _path = _history[_historyIndex].path;
      _title = _history[_historyIndex].title;
    } else {
      _path = widget.path;
      _title = widget.title;
      _history.add(NavStep(_path, _title));
      _historyIndex = 0;
    }
    _controller = BrowserController(initialPath: _path);
    _controller.load();
    _controller.addListener(_onControllerNotify);
    _scroll.addListener(_onScroll);
    DropController.instance.revision.addListener(_onDropRevision);
    TransferQueue.instance.completed.addListener(_onTransferCompleted);
    ViewStore.instance.loadIfNeeded();
    FavoritesStore.instance.loadIfNeeded();
    LabelStore.instance.loadIfNeeded();
    widget.controller?._attach(_handleBack);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onLocationChanged?.call(_path, _title);
      _syncState();
      final offset = _history[_historyIndex].offset;
      if (offset > 0) _jumpTo(offset);
    });
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
    TransferQueue.instance.completed.removeListener(_onTransferCompleted);
    widget.controller?._detach();
    _controller.removeListener(_onControllerNotify);
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onTransferCompleted() {
    if (mounted) _controller.refresh();
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
      _history.add(NavStep(path, title));
      _historyIndex = _history.length - 1;
    });
    RecentStore.instance.record(path, title, true);
    widget.onLocationChanged?.call(_path, _title);
    _syncState();
    await _controller.navigateTo(path);
    if (mounted) {
      _jumpTo(0);
      _updateDropTarget();
    }
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
    widget.onLocationChanged?.call(_path, _title);
    _syncState();
    _controller.navigateTo(step.path);
    _jumpTo(step.offset);
    _updateDropTarget();
  }

  void _onScroll() {
    if (_historyIndex >= 0 &&
        _historyIndex < _history.length &&
        _scroll.hasClients) {
      _history[_historyIndex].offset = _scroll.offset;
    }
  }

  /// 恢复滚动位置；列表尚未布局完成时多试几帧。
  void _jumpTo(double offset, [int attempt = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (max == 0 && offset > 0 && attempt < 5) {
        _jumpTo(offset, attempt + 1);
        return;
      }
      _scroll.jumpTo(offset.clamp(0.0, max));
    });
  }

  void _goUp() {
    final parent = parentOf(_path);
    if (parent == _path) return;
    final title = parent == '/' ? '/' : baseName(parent);
    _navigateToPath(parent, title.isEmpty ? parent : title);
  }

  void _handleBack() {
    if (_controller.selectionMode) {
      _controller.clearSelection();
      return;
    }
    if (_canGoBack) {
      _goHistory(_historyIndex - 1);
      return;
    }
    final onExit = widget.onExit;
    if (onExit != null) {
      onExit();
      return;
    }
    Navigator.of(context).maybePop();
  }

  /// 记录上一次的多选状态，用于在进入 / 退出多选时同步返回能力。
  bool _lastSelection = false;

  void _onControllerNotify() {
    final selection = _controller.selectionMode;
    if (selection != _lastSelection) {
      _lastSelection = selection;
      _syncState();
    }
  }

  /// 把当前会话状态同步给父级（标签页容器）或全局会话记录。
  void _syncState() {
    final state = TabSession(
      path: _path,
      title: _title,
      history: List<NavStep>.unmodifiable(_history),
      index: _historyIndex,
    );
    // 多选状态下，返回键应优先退出多选。
    final canBack = _canGoBack || _controller.selectionMode;
    final controller = widget.controller;
    if (controller != null) {
      controller._update(canBack, state);
    } else {
      SessionStore.instance.record(BrowserSession(tabs: [state], active: 0));
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
        LabelStore.instance,
        TransferQueue.instance,
        ViewStore.instance,
      ]),
      builder: (context, _) {
        return PopScope(
          canPop: !_canGoBack && !_controller.selectionMode,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _handleBack();
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
        title: Text(tr('已选择 {p0} 项', {'p0': _controller.selectedCount})),
        actions: [
          PopupMenuButton<String>(
            tooltip: tr('选择'),
            icon: const Icon(Icons.checklist_rounded),
            onSelected: _onSelectAction,
            itemBuilder: (_) => [
              PopupMenuItem(value: 'all', child: Text(tr('全选'))),
              PopupMenuItem(value: 'invert', child: Text(tr('反选'))),
              PopupMenuDivider(),
              PopupMenuItem(value: 'type', child: Text(tr('按类型选择'))),
              PopupMenuItem(value: 'condition', child: Text(tr('按条件选择'))),
            ],
          ),
        ],
      );
    }

    return AppBar(
      automaticallyImplyLeading: false,
      leadingWidth: ViewStore.instance.showUp ? 144 : 96,
      leading: Row(
        children: [
          if (ViewStore.instance.showUp)
            IconButton(
              tooltip: tr('向上一级'),
              icon: const Icon(Icons.arrow_upward_rounded),
              onPressed: parentOf(_path) == _path ? null : _goUp,
            ),
          IconButton(
            tooltip: tr('后退'),
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: _handleBack,
          ),
          IconButton(
            tooltip: tr('前进'),
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
          tooltip: tr('传输'),
          icon: Badge(
            isLabelVisible: TransferQueue.instance.activeCount > 0,
            label: Text('${TransferQueue.instance.activeCount}'),
            child: const Icon(Icons.swap_vert_rounded),
          ),
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const TransferScreen()),
            );
          },
        ),
        PopupMenuButton<String>(
          tooltip: tr('更多'),
          onSelected: _onMenuSelected,
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'favorite',
              child: Row(
                children: [
                  if (_isFavorite)
                    const Icon(Icons.star_rounded, size: 18)
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 8),
                  Text(_isFavorite ? tr('取消收藏') : tr('收藏')),
                ],
              ),
            ),
            PopupMenuItem(value: 'search', child: Text(tr('搜索'))),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'refresh', child: Text(tr('刷新'))),
            PopupMenuItem(
              value: 'hidden',
              child: Row(
                children: [
                  if (_controller.showHidden)
                    const Icon(Icons.check_rounded, size: 18)
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 8),
                  Text(tr('显示隐藏文件')),
                ],
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'create', child: Text(tr('新建…'))),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'view',
              child: Text(
                ViewStore.instance.grid ? tr('切换为列表视图') : tr('切换为网格视图'),
              ),
            ),
            PopupMenuItem(
              value: 'iconSize',
              child: Text(tr('图标大小（{p0}）', {'p0': ViewStore.instance.iconSizeLabel})),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'sort', child: Text(tr('排序方式'))),
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
              child: Text(tr('重试')),
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
              tr('空文件夹'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    }

    if (ViewStore.instance.grid) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final extent = ViewStore.instance.tileExtent;
          final count = (constraints.maxWidth / extent).floor().clamp(2, 8);
          return GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
              childAspectRatio: 0.85,
            ),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return GridEntryTile(
                entry: entry,
                selectionMode: _controller.selectionMode,
                selected: _controller.isSelected(entry.path),
                labelColor: LabelStore.instance.colorFor(entry.path),
                iconExtent: ViewStore.instance.iconExtent,
                onTap: () => _controller.selectionMode
                    ? _controller.toggleSelected(entry.path)
                    : _openEntry(entry),
                onLongPress: () => _controller.toggleSelected(entry.path),
                onMenu: () => _showEntrySheet(entry),
              );
            },
          );
        },
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return EntryTile(
          entry: entry,
          selectionMode: _controller.selectionMode,
          selected: _controller.isSelected(entry.path),
          labelColor: LabelStore.instance.colorFor(entry.path),
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
              label: tr('复制'),
              onTap: () => _copySelection(move: false),
            ),
            _BarAction(
              icon: Icons.drive_file_move_rounded,
              label: tr('移动'),
              onTap: () => _copySelection(move: true),
            ),
            _BarAction(
              icon: Icons.delete_outline_rounded,
              label: tr('删除'),
              onTap: _deleteSelection,
            ),
            _BarAction(
              icon: Icons.more_horiz_rounded,
              label: tr('更多'),
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
                    tr('已{p0} {p1} 项', {'p0': clipboard.isMove ? tr('剪切') : tr('复制'), 'p1': clipboard.count}),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(onPressed: clipboard.clear, child: Text(tr('取消'))),
                const SizedBox(width: 4),
                FilledButton(onPressed: _paste, child: Text(tr('粘贴'))),
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
        _snack(tr('已取消收藏'));
      } else {
        await FavoritesStore.instance.add(_title, _path);
        _snack(tr('已收藏「{_title}」', {'_title': _title}));
      }
    } catch (error) {
      _snack('$error');
    }
  }

  void _navigateTo(PathCrumb crumb) {
    _navigateToPath(crumb.path, crumb.label);
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchScreen(root: _path, title: _title),
      ),
    );
  }

  void _onMenuSelected(String value) {
    switch (value) {
      case 'favorite':
        _toggleFavorite();
      case 'search':
        _openSearch();
      case 'refresh':
        _controller.refresh();
      case 'hidden':
        _controller.setShowHidden(!_controller.showHidden);
      case 'create':
        _showCreateSheet();
      case 'view':
        ViewStore.instance.toggleGrid();
      case 'iconSize':
        _showIconSizeSheet();
      case 'sort':
        _showSortSheet();
    }
  }

  Future<void> _showIconSizeSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final size in const ['small', 'medium', 'large'])
              ListTile(
                leading: const Icon(Icons.photo_size_select_large_rounded),
                title: Text(switch (size) {
                  'small' => tr('小'),
                  'large' => tr('大'),
                  _ => tr('中'),
                }),
                trailing: ViewStore.instance.iconSize == size
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  ViewStore.instance.setIconSize(size);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _onSelectAction(String value) {
    switch (value) {
      case 'all':
        _controller.selectAll();
      case 'invert':
        _controller.invertSelection();
      case 'type':
        _showSelectByType();
      case 'condition':
        _showSelectByCondition();
    }
  }

  Future<void> _showSelectByType() async {
    final category = await showModalBottomSheet<FileCategory>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final category in FileCategory.values)
              ListTile(
                leading: Icon(_selectionCategoryIcon(category)),
                title: Text(_selectionCategoryLabel(category)),
                onTap: () => Navigator.pop(sheetContext, category),
              ),
          ],
        ),
      ),
    );
    if (category == null || !mounted) return;
    _controller.selectMatching(
      (entry) => categoryOf(entry.extension, isDir: entry.isDir) == category,
    );
  }

  Future<void> _showSelectByCondition() async {
    final sizeController = TextEditingController();
    final daysController = TextEditingController();
    final extController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('按条件选择')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: sizeController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: tr('最小大小（MB，可空）')),
              ),
              TextField(
                controller: daysController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: tr('最近 N 天内修改（可空）'),
                ),
              ),
              TextField(
                controller: extController,
                decoration: InputDecoration(
                  labelText: tr('扩展名，逗号分隔（可空）'),
                  hintText: tr('例如 jpg,png,mp4'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr('选择')),
          ),
        ],
      ),
    );
    final minBytes =
        (double.tryParse(sizeController.text.trim()) ?? 0) * 1024 * 1024;
    final days = int.tryParse(daysController.text.trim()) ?? 0;
    final extensions = extController.text
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    sizeController.dispose();
    daysController.dispose();
    extController.dispose();
    if (confirmed != true || !mounted) return;

    final cutoff = days > 0
        ? DateTime.now()
                  .subtract(Duration(days: days))
                  .millisecondsSinceEpoch ~/
              1000
        : 0;
    _controller.selectMatching((entry) {
      if (entry.isDir) return false;
      if (minBytes > 0 && entry.size < minBytes) return false;
      if (cutoff > 0 && entry.modified < cutoff) return false;
      if (extensions.isNotEmpty &&
          !extensions.contains(entry.extension.toLowerCase())) {
        return false;
      }
      return true;
    });
  }

  String _selectionCategoryLabel(FileCategory category) => switch (category) {
    FileCategory.folder => tr('文件夹'),
    FileCategory.image => tr('图片'),
    FileCategory.video => tr('视频'),
    FileCategory.audio => tr('音频'),
    FileCategory.document => tr('文档'),
    FileCategory.text => tr('文本'),
    FileCategory.archive => tr('压缩包'),
    FileCategory.apk => tr('安装包'),
    FileCategory.other => tr('其它'),
  };

  IconData _selectionCategoryIcon(FileCategory category) => switch (category) {
    FileCategory.folder => Icons.folder_rounded,
    FileCategory.image => Icons.image_rounded,
    FileCategory.video => Icons.movie_rounded,
    FileCategory.audio => Icons.music_note_rounded,
    FileCategory.document => Icons.description_rounded,
    FileCategory.text => Icons.article_rounded,
    FileCategory.archive => Icons.folder_zip_rounded,
    FileCategory.apk => Icons.android_rounded,
    FileCategory.other => Icons.insert_drive_file_rounded,
  };

  Future<void> _create({required bool folder}) async {
    final name = await showNameDialog(
      context,
      title: folder ? tr('新建文件夹') : tr('新建文件'),
      hintText: folder ? tr('文件夹名称') : tr('文件名'),
      confirmLabel: tr('创建'),
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

  Future<void> _createSymlink() async {
    final targetController = TextEditingController();
    final nameController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('新建符号链接')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: targetController,
                decoration: InputDecoration(
                  labelText: tr('链接目标'),
                  hintText: tr('绝对路径或相对路径'),
                ),
              ),
              TextField(
                controller: nameController,
                decoration: InputDecoration(labelText: tr('链接名称')),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr('创建')),
          ),
        ],
      ),
    );
    final target = targetController.text.trim();
    final name = nameController.text.trim();
    targetController.dispose();
    nameController.dispose();
    if (confirmed != true || target.isEmpty || name.isEmpty || !mounted) return;
    final link = joinPath(_controller.path, name);
    try {
      await _service.symlink(target, link);
      await _controller.refresh();
      _snack(tr('已创建符号链接'));
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _rename(FileEntry entry) async {
    final name = await showNameDialog(
      context,
      title: tr('重命名'),
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

  Future<void> _compress(List<String> paths) async {
    if (paths.isEmpty) return;
    final format = await pickArchiveFormat(context);
    if (format == null || !mounted) return;
    final base = paths.length == 1
        ? _stem(paths.first)
        : (_title.isEmpty ? 'archive' : _title);
    final request = await showCompressDialog(
      context,
      defaultName: '$base.${format.extension}',
      allowPassword: format.supportsPassword,
    );
    if (request == null || !mounted) return;
    final fileName = request.name.toLowerCase().endsWith('.${format.extension}')
        ? request.name
        : '${request.name}.${format.extension}';
    final dest = joinPath(_controller.path, fileName);
    try {
      await runWithJobProgress<void>(
        context,
        tr('正在压缩'),
        (jobId) => _service.archiveCreate(
          paths,
          dest,
          password: request.password,
          jobId: jobId,
        ),
      );
      await _controller.refresh();
      _snack(tr('已创建「{fileName}」', {'fileName': fileName}));
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _extract(FileEntry entry) async {
    final folder = archiveStem(entry.name);
    final dest = joinPath(_controller.path, folder);
    final ok = await runArchiveExtract(
      context,
      archivePath: entry.path,
      dest: dest,
    );
    if (!mounted || !ok) return;
    await _controller.refresh();
    _snack(tr('已解压到「{folder}」', {'folder': folder}));
  }

  void _openArchive(FileEntry entry) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) =>
                ArchiveViewerScreen(entry: entry, parentDir: _controller.path),
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
    _snack(tr('已{p0} {p1} 项', {'p0': move ? tr('剪切') : tr('复制'), 'p1': paths.length}));
  }

  Future<void> _deleteSelection() async {
    final paths = _controller.selectedPaths.toList();
    await _delete(paths);
  }

  Future<void> _vaultMoveSelection() async {
    final paths = _controller.selectedPaths.toList();
    if (paths.isEmpty) return;
    try {
      final result = await _service.vaultMove(paths);
      _controller.clearSelection();
      await _controller.refresh();
      _snack(tr('已移入隐私空间 {p0} 项', {'p0': result.count}), errors: result.errors);
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _secureDeleteSelection() async {
    final paths = _controller.selectedPaths.toList();
    if (paths.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('安全删除')),
        content: Text(tr('将覆盖写入后永久删除 {p0} 项，无法恢复。是否继续？', {'p0': paths.length})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr('安全删除')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final result = await _service.secureDelete(paths);
      _controller.clearSelection();
      await _controller.refresh();
      _snack(tr('已安全删除 {p0} 项', {'p0': result.deleted}), errors: result.errors);
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _delete(List<String> paths) async {
    if (paths.isEmpty) return;
    final allowTrash = paths.every((path) => !isRemotePath(path));
    final toTrash = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: Text(tr('删除')),
          content: Text(
            allowTrash
                ? tr('确定删除选中的 {p0} 项吗？\n移入回收站后可在「回收站」中恢复。', {'p0': paths.length})
                : tr('确定删除选中的 {p0} 项吗？\n网络位置不支持回收站，将永久删除。', {'p0': paths.length}),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr('取消')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr('永久删除'), style: TextStyle(color: scheme.error)),
            ),
            if (allowTrash)
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(tr('移入回收站')),
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
      if (result.trashed > 0) parts.add(tr('移入回收站 {p0} 项', {'p0': result.trashed}));
      if (result.deleted > 0) parts.add(tr('永久删除 {p0} 项', {'p0': result.deleted}));
      _snack(parts.isEmpty ? tr('删除失败') : parts.join('，'), errors: result.errors);
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _paste() async {
    final clipboard = TransferClipboard.instance;
    if (clipboard.isEmpty) return;
    final paths = clipboard.paths;
    final move = clipboard.isMove;
    clipboard.clear();
    TransferQueue.instance.enqueue(paths, _controller.path, isMove: move);
    _snack(tr('已加入传输队列（{p0} 项），可在「传输」中查看', {'p0': paths.length}));
  }

  Future<void> _share(FileEntry entry) async {
    if (entry.isDir) {
      _snack(tr('暂不支持分享文件夹'));
      return;
    }
    final ok = await PlatformService.shareFile(
      entry.path,
      mime: mimeOfExtension(entry.extension),
    );
    if (!ok) _snack(tr('分享失败'));
  }

  void _copyPath(List<String> paths) {
    if (paths.isEmpty) return;
    Clipboard.setData(ClipboardData(text: paths.join('\n')));
    _snack(paths.length == 1 ? tr('已复制路径') : tr('已复制 {p0} 条路径', {'p0': paths.length}));
  }

  Future<void> _createShortcut(FileEntry entry) async {
    final ok = await PlatformService.createShortcut(entry.name, entry.path);
    if (!mounted) return;
    _snack(ok ? tr('请在系统弹窗中确认') : tr('当前桌面不支持创建快捷方式'));
  }

  Future<void> _pickLabel(List<String> paths) async {
    if (paths.isEmpty) return;
    final current = paths.length == 1
        ? LabelStore.instance.indexFor(paths.first)
        : null;
    final choice = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('标签颜色'),
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    for (var i = 0; i < labelPalette.length; i++)
                      GestureDetector(
                        onTap: () => Navigator.pop(sheetContext, i),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: labelPalette[i],
                            shape: BoxShape.circle,
                            border: current == i
                                ? Border.all(color: scheme.onSurface, width: 3)
                                : null,
                          ),
                        ),
                      ),
                    GestureDetector(
                      onTap: () => Navigator.pop(sheetContext, -1),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.outline),
                        ),
                        child: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    await LabelStore.instance.setLabels(paths, choice < 0 ? null : choice);
    _snack(choice < 0 ? tr('已移除标签') : tr('已设置标签'));
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
                title: Text(tr('新建文件夹')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _create(folder: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.note_add_rounded),
                title: Text(tr('新建文件')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _create(folder: false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: Text(tr('新建符号链接')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _createSymlink();
                },
              ),
              if (!clipboard.isEmpty)
                ListTile(
                  leading: const Icon(Icons.content_paste_rounded),
                  title: Text(tr('粘贴 ({p0} 项)', {'p0': clipboard.count})),
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
                title: Text(_controller.sortAscending ? tr('升序') : tr('降序')),
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
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: Icon(
                  entry.isDir
                      ? Icons.folder_open_rounded
                      : Icons.open_in_new_rounded,
                ),
                title: Text(entry.isDir ? tr('打开') : tr('打开方式')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openEntry(entry);
                },
              ),
              if (!entry.isDir)
                ListTile(
                  leading: const Icon(Icons.text_snippet_outlined),
                  title: Text(tr('以文本方式打开')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            ViewerScreen(entry: entry, forceText: true),
                      ),
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline_rounded),
                title: Text(tr('重命名')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _rename(entry);
                },
              ),
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: Text(tr('压缩')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _compress([entry.path]);
                },
              ),
              if (isSupportedArchive(entry.name)) ...[
                ListTile(
                  leading: const Icon(Icons.unarchive_outlined),
                  title: Text(tr('解压到此处')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _extract(entry);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.list_alt_rounded),
                  title: Text(tr('查看归档内容')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openArchive(entry);
                  },
                ),
              ],
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: Text(tr('复制')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  TransferClipboard.instance.set([entry.path], move: false);
                  _snack(tr('已复制到剪贴板'));
                },
              ),
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: Text(tr('复制路径')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _copyPath([entry.path]);
                },
              ),
              if (!entry.isDir)
                ListTile(
                  leading: const Icon(Icons.tag_rounded),
                  title: Text(tr('校验和')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showHashDialog(context, entry);
                  },
                ),
              if (isImageExtension(entry.extension))
                ListTile(
                  leading: const Icon(Icons.photo_camera_back_outlined),
                  title: Text(tr('媒体信息')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showMediaInfoDialog(context, entry);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.label_outline_rounded),
                title: Text(tr('标签颜色')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickLabel([entry.path]);
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_rounded),
                title: Text(tr('移动')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  TransferClipboard.instance.set([entry.path], move: true);
                  _snack(tr('已剪切到剪贴板'));
                },
              ),
              if (!entry.isDir)
                ListTile(
                  leading: const Icon(Icons.ios_share_rounded),
                  title: Text(tr('分享')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _share(entry);
                  },
                ),
              if (entry.isDir)
                ListTile(
                  leading: const Icon(Icons.add_to_home_screen_rounded),
                  title: Text(tr('创建桌面快捷方式')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _createShortcut(entry);
                  },
                ),
              if (entry.isDir)
                ListTile(
                  leading: const Icon(Icons.straighten_rounded),
                  title: Text(tr('计算大小')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showFolderSizeDialog(context, entry);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: Text(tr('详细信息')),
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
                  tr('删除'),
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
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline_rounded),
                title: Text(tr('重命名')),
                enabled: _controller.singleSelected != null,
                onTap: () {
                  final entry = _controller.singleSelected;
                  Navigator.pop(sheetContext);
                  if (entry != null) _rename(entry);
                },
              ),
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: Text(tr('压缩')),
                onTap: () {
                  final paths = _controller.selectedEntries
                      .map((e) => e.path)
                      .toList();
                  Navigator.pop(sheetContext);
                  _compress(paths);
                },
              ),
              ListTile(
                leading: const Icon(Icons.ios_share_rounded),
                title: Text(tr('分享')),
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
                leading: const Icon(Icons.link_rounded),
                title: Text(tr('复制路径')),
                onTap: () {
                  final paths = _controller.selectedEntries
                      .map((e) => e.path)
                      .toList();
                  Navigator.pop(sheetContext);
                  _copyPath(paths);
                },
              ),
              ListTile(
                leading: const Icon(Icons.label_outline_rounded),
                title: Text(tr('标签颜色')),
                onTap: () {
                  final paths = _controller.selectedEntries
                      .map((e) => e.path)
                      .toList();
                  Navigator.pop(sheetContext);
                  _pickLabel(paths);
                },
              ),
              ListTile(
                leading: const Icon(Icons.lock_outline_rounded),
                title: Text(tr('移入隐私空间')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _vaultMoveSelection();
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever_rounded),
                title: Text(tr('安全删除')),
                subtitle: Text(tr('覆盖写入后永久删除')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _secureDeleteSelection();
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: Text(tr('详细信息')),
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
    showOrdoSnack(context, text);
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

/// 浏览历史中的一步（路径 + 标题）。
