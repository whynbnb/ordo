import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/ordo_exception.dart';
import '../services/ordo_service.dart';
import '../state/connections.dart';
import '../state/drop_controller.dart';
import '../state/favorites.dart';
import '../state/home_layout.dart';
import '../state/route_observer.dart';
import '../state/storage_events.dart';
import 'connection_edit.dart';
import 'dialogs.dart';
import 'directory_picker.dart';
import 'drop_overlay.dart';
import 'file_picker.dart';
import 'analyzer_screen.dart';
import 'cleanup_screen.dart';
import 'trend_screen.dart';
import 'vault_screen.dart';
import 'qr_dialog.dart';
import 'recent_screen.dart';
import 'server_screen.dart';
import 'tabbed_browser.dart';
import 'settings_screen.dart';
import 'trash_screen.dart';
import '../i18n/i18n.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.version});

  final String? version;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, RouteAware {
  final OrdoService _service = OrdoService.instance;
  final ConnectionStore _connections = ConnectionStore.instance;
  final FavoritesStore _favorites = FavoritesStore.instance;

  List<StorageRoot> _roots = const [];
  List<_QuickFolder> _quickFolders = const [];
  bool _loading = true;
  String? _error;

  /// 上次已知的可移动卷（路径 -> 名称），用于判断插拔并提示。
  Map<String, String> _knownRemovable = const {};
  bool _loadedOnce = false;

  List<_QuickFolder> get _quickCandidates => const [
    _QuickFolder('下载', 'Download', Icons.download_rounded),
    _QuickFolder('图片', 'Pictures', Icons.photo_library_rounded),
    _QuickFolder('相机', 'DCIM', Icons.photo_camera_rounded),
    _QuickFolder('音乐', 'Music', Icons.library_music_rounded),
    _QuickFolder('视频', 'Movies', Icons.video_library_rounded),
    _QuickFolder('文档', 'Documents', Icons.folder_special_rounded),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connections.addListener(_onStoreChanged);
    _favorites.addListener(_onStoreChanged);
    HomeLayoutStore.instance.addListener(_onLayoutChanged);
    StorageEvents.instance.revision.addListener(_onStorageChanged);
    _connections.load();
    _favorites.loadIfNeeded();
    HomeLayoutStore.instance.loadIfNeeded();
    _load();
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
  void didPush() => _updateDropTarget();

  @override
  void didPopNext() => _updateDropTarget();

  void _updateDropTarget() {
    // 只有当前可见页面才决定拖放目标：首页会一直挂载在浏览页下方，
    // 应用恢复前台时（例如开始跨应用拖放）不能把正在浏览的目录覆盖掉。
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    String path = '/storage/emulated/0';
    for (final root in _roots) {
      if (root.kind == 'internal') {
        path = root.path;
        break;
      }
    }
    DropController.instance.setActive(path, tr('内部存储'));
  }

  @override
  void dispose() {
    ordoRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _connections.removeListener(_onStoreChanged);
    _favorites.removeListener(_onStoreChanged);
    HomeLayoutStore.instance.removeListener(_onLayoutChanged);
    StorageEvents.instance.revision.removeListener(_onStorageChanged);
    super.dispose();
  }

  void _onLayoutChanged() {
    if (mounted) setState(() {});
  }

  void _onStorageChanged() {
    // 外部存储插拔：静默刷新卷列表，并在 _load 中给出提示。
    _load(showSpinner: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到前台时重新探测存储卷，以便识别刚插入 / 拔出的 U 盘或存储卡。
    if (state == AppLifecycleState.resumed) {
      _load(showSpinner: false);
    }
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load({bool showSpinner = true}) async {
    if (showSpinner) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final roots = await _service.storageRoots();
      final quick = <_QuickFolder>[];
      StorageRoot? internal;
      for (final root in roots) {
        if (root.kind == 'internal') {
          internal = root;
          break;
        }
      }
      if (internal != null) {
        for (final folder in _quickCandidates) {
          final path = joinPath(internal.path, folder.segment);
          try {
            final entry = await _service.stat(path);
            if (entry.isDir) {
              quick.add(folder.withPath(path));
            }
          } on OrdoException {
            // 不存在则忽略。
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _roots = roots;
        _quickFolders = quick;
        _loading = false;
        _error = null;
      });
      _announceVolumeChanges(roots);
      _updateDropTarget();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // 静默刷新失败时保留原列表。
        if (showSpinner) _error = '$error';
      });
    }
  }

  /// 对比可移动卷的变化并在插入 / 拔出时提示。首次加载只记录基线。
  void _announceVolumeChanges(List<StorageRoot> roots) {
    final removable = <String, String>{
      for (final root in roots)
        if (root.removable) root.path: root.name,
    };
    if (!_loadedOnce) {
      _loadedOnce = true;
      _knownRemovable = removable;
      return;
    }

    final added = removable.entries
        .where((entry) => !_knownRemovable.containsKey(entry.key))
        .toList();
    final removed = _knownRemovable.entries
        .where((entry) => !removable.containsKey(entry.key))
        .toList();
    _knownRemovable = removable;

    if (added.isNotEmpty) {
      _promptStorageAdded(added.first.key, added.first.value);
    } else if (removed.isNotEmpty) {
      _snack(tr('外部存储已移除：「{p0}」', {'p0': tr(removed.first.value)}));
    }
  }

  void _promptStorageAdded(String path, String name) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            tr('已检测到外部存储「{name}」', {'name': tr(name)}),
          ),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: tr('打开'),
            onPressed: () => _openPath(path, tr(name)),
          ),
        ),
      );
  }

  void _openPath(String path, String title) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => TabbedBrowserScreen(path: path, title: title),
          ),
        )
        // 返回时静默刷新，及时反映已拔出的外部介质。
        .then((_) {
          if (mounted) _load(showSpinner: false);
        });
  }

  String get _primaryPath =>
      _roots.isNotEmpty ? _roots.first.path : '/storage/emulated/0';

  String get _primaryName =>
      tr(_roots.isNotEmpty ? _roots.first.name : '内部存储');

  List<_QuickFolder> get _orderedQuickFolders {
    final order = HomeLayoutStore.instance.quick;
    final map = {for (final folder in _quickFolders) folder.segment: folder};
    final result = <_QuickFolder>[];
    for (final segment in order) {
      final folder = map[segment];
      if (folder != null) result.add(folder);
    }
    return result;
  }

  Widget _toolCard(BuildContext context, String id) {
    final tool = homeTools.firstWhere(
      (t) => t.id == id,
      orElse: () => HomeTool(id, id, ''),
    );
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
        alpha: 0.5,
      ),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(_toolIcon(id)),
        title: Text(tr(tool.title)),
        subtitle: Text(tr(tool.subtitle)),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _openTool(id),
      ),
    );
  }

  IconData _toolIcon(String id) => switch (id) {
    'recent' => Icons.history_rounded,
    'trash' => Icons.delete_outline_rounded,
    'analyzer' => Icons.pie_chart_outline_rounded,
    'cleanup' => Icons.cleaning_services_rounded,
    'trend' => Icons.show_chart_rounded,
    'vault' => Icons.lock_outline_rounded,
    _ => Icons.widgets_outlined,
  };

  void _openTool(String id) {
    switch (id) {
      case 'recent':
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const RecentScreen()),
        );
      case 'trash':
        Navigator.of(context)
            .push(
              MaterialPageRoute<void>(builder: (_) => const TrashScreen()),
            )
            .then((_) {
              if (mounted) _load(showSpinner: false);
            });
      case 'analyzer':
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AnalyzerScreen()),
        );
      case 'cleanup':
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                CleanupScreen(root: _primaryPath, title: _primaryName),
          ),
        );
      case 'trend':
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                TrendScreen(root: _primaryPath, title: _primaryName),
          ),
        );
      case 'vault':
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const VaultScreen()),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('安序')),
        actions: [
          IconButton(
            tooltip: tr('文件服务器'),
            icon: const Icon(Icons.router_rounded),
            onPressed: () {
              Navigator.of(context)
                  .push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ServerScreen(),
                    ),
                  )
                  .then((_) {
                    if (mounted) _load(showSpinner: false);
                  });
            },
          ),
          IconButton(
            tooltip: tr('设置'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(version: widget.version),
                ),
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          RefreshIndicator(onRefresh: () => _load(), child: _buildBody()),
          const DropOverlay(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.error_outline_rounded, size: 48),
                  const SizedBox(height: 16),
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: () => _load(),
                    child: Text(tr('重试')),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _sectionTitle(tr('存储')),
        const SizedBox(height: 8),
        if (_roots.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text(tr('未发现可用的存储卷'))),
          )
        else
          for (final root in _roots) ...[
            _StorageCard(
              root: root,
              onTap: () => _openPath(root.path, tr(root.name)),
            ),
            const SizedBox(height: 12),
          ],
        if (_orderedQuickFolders.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionTitle(tr('常用')),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.1,
            children: [
              for (final folder in _orderedQuickFolders)
                _QuickCard(
                  folder: folder,
                  onTap: () => _openPath(folder.path!, tr(folder.label)),
                ),
            ],
          ),
        ],
        if (_favorites.items.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionTitle(tr('收藏')),
          const SizedBox(height: 8),
          for (final favorite in _favorites.items) ...[
            _FavoriteCard(
              favorite: favorite,
              subtitle: _favoriteSubtitle(favorite),
              onTap: () => _openPath(favorite.path, favorite.name),
              onRemove: () => _favorites.remove(favorite.path),
            ),
            const SizedBox(height: 10),
          ],
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _sectionTitle(tr('网络位置'))),
            PopupMenuButton<String>(
              tooltip: tr('更多'),
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: _onNetworkMenu,
              itemBuilder: (_) => [
                PopupMenuItem(value: 'import', child: Text(tr('导入连接'))),
                PopupMenuItem(value: 'export', child: Text(tr('导出连接'))),
              ],
            ),
            TextButton.icon(
              onPressed: () => _editConnection(null),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(tr('添加')),
            ),
          ],
        ),
        for (final profile in _connections.profiles) ...[
          _ConnectionCard(
            profile: profile,
            onTap: () => _openPath(profile.rootUri, profile.name),
            onEdit: () => _editConnection(profile),
            onTest: () => _testConnection(profile),
            onQr: () => _showConnectionQr(profile),
            onDelete: () => _deleteConnection(profile),
          ),
          const SizedBox(height: 10),
        ],
        if (_connections.profiles.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              tr('添加 WebDAV / FTP / SMB 连接后可在此访问。'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 24),
        _sectionTitle(tr('工具')),
        const SizedBox(height: 8),
        for (final id in HomeLayoutStore.instance.tools) ...[
          _toolCard(context, id),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 24),
        Center(
          child: Text(
            tr('安序 Ordo{p0}', {'p0': widget.version == null ? '' : ' · v${widget.version}'}),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      ],
    );
  }

  void _onNetworkMenu(String value) {
    switch (value) {
      case 'import':
        _importConnections();
      case 'export':
        _exportConnections();
    }
  }

  Future<void> _exportConnections() async {
    final dir = await pickDirectory(
      context,
      initial: '/storage/emulated/0/Download',
    );
    if (dir == null || !mounted) return;
    final path = joinPath(dir, 'ordo_connections.json');
    try {
      await _service.writeText(path, _connections.exportJson());
      _snack(tr('已导出到 {path}', {'path': path}));
    } catch (error) {
      _snack(tr('导出失败：{error}', {'error': error}));
    }
  }

  Future<void> _importConnections() async {
    final file = await pickFile(
      context,
      initial: '/storage/emulated/0/Download',
    );
    if (file == null || !mounted) return;
    try {
      final text = (await _service.readText(file)).content;
      final count = await _connections.importJson(text);
      _snack(tr('已导入 {count} 个连接', {'count': count}));
    } catch (error) {
      _snack(tr('导入失败：{error}', {'error': error}));
    }
  }

  Future<void> _showConnectionQr(ConnectionProfile profile) async {
    final json = profile.toJson()
      ..remove('id')
      ..remove('password');
    final data = jsonEncode({'app': 'ordo', 'version': 1, 'profile': json});
    if (!mounted) return;
    await showQrDialog(context, title: tr('连接二维码'), data: data);
  }

  Future<void> _editConnection(ConnectionProfile? existing) async {
    final result = await showConnectionEditor(context, initial: existing);
    if (result == null || !mounted) return;
    try {
      await _connections.save(result);
      _snack(tr('已保存「{p0}」', {'p0': result.name}));
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _testConnection(ConnectionProfile profile) async {
    _snack(tr('正在测试「{p0}」…', {'p0': profile.name}));
    try {
      await _connections.test(profile);
      _snack(tr('连接成功：{p0}', {'p0': profile.name}));
    } catch (error) {
      _snack(tr('连接失败：{error}', {'error': error}));
    }
  }

  Future<void> _deleteConnection(ConnectionProfile profile) async {
    final confirmed = await showConfirmDialog(
      context,
      title: tr('删除连接'),
      message: tr('确定删除「{p0}」吗？', {'p0': profile.name}),
      confirmLabel: tr('删除'),
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await _connections.remove(profile);
    } catch (error) {
      _snack('$error');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w600),
    );
  }

  /// 收藏项副标题：远程收藏用「协议 · 连接名 + 路径」代替带连接 ID 的原始 URI。
  String _favoriteSubtitle(Favorite favorite) {
    if (!isRemotePath(favorite.path)) return favorite.path;
    final uri = Uri.tryParse(favorite.path);
    if (uri == null) return favorite.path;
    // `Uri.path` 会做百分号编码，这里解码回可读文本（中文文件名等）。
    var inner = uri.path.isEmpty ? '/' : uri.path;
    try {
      inner = Uri.decodeComponent(inner);
    } catch (_) {
      // 保留原始文本。
    }
    final label = switch (uri.scheme) {
      'smb' => 'SMB',
      'ftp' => 'FTP',
      _ => 'WebDAV',
    };
    String? name;
    for (final profile in _connections.profiles) {
      if (profile.id == uri.host) {
        name = profile.name;
        break;
      }
    }
    if (name == null || name.isEmpty) {
      return '$label · $inner';
    }
    return '$label · $name$inner';
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.root, required this.onTap});

  final StorageRoot root;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = root.usedRatio.clamp(0.0, 1.0);
    final color = ratio > 0.9
        ? scheme.error
        : (ratio > 0.7 ? const Color(0xFFFFA000) : scheme.primary);

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: root.readable ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(switch (root.kind) {
                    'usb' => Icons.usb_rounded,
                    'external' => Icons.sd_card_rounded,
                    _ =>
                      root.removable
                          ? Icons.sd_card_rounded
                          : Icons.smartphone_rounded,
                  }, color: root.readable ? scheme.primary : scheme.outline),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr(root.name),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          root.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: scheme.outline),
                ],
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 6,
                  backgroundColor: scheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr('已用 {p0} / 共 {p1}   可用 {p2}', {'p0': formatBytes(root.used), 'p1': formatBytes(root.total), 'p2': formatBytes(root.free)}),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (!root.readable) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 14,
                      color: scheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tr('系统未向本应用开放该卷的访问权限'),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.error),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickCard extends StatelessWidget {
  const _QuickCard({required this.folder, required this.onTap});

  final _QuickFolder folder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(folder.icon, color: scheme.primary),
            const SizedBox(height: 8),
            Text(
              tr(folder.label),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickFolder {
  const _QuickFolder(this.label, this.segment, this.icon, [this.path]);

  final String label;
  final String segment;
  final IconData icon;
  final String? path;

  _QuickFolder withPath(String value) =>
      _QuickFolder(label, segment, icon, value);
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.profile,
    required this.onTap,
    required this.onEdit,
    required this.onTest,
    required this.onQr,
    required this.onDelete,
  });

  final ConnectionProfile profile;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onTest;
  final VoidCallback onQr;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, String label) = switch (profile.kind) {
      'smb' => (Icons.lan_rounded, 'SMB'),
      'sftp' => (Icons.terminal_rounded, 'SFTP'),
      'ftp' => (Icons.cloud_upload_rounded, 'FTP'),
      _ => (Icons.cloud_rounded, 'WebDAV'),
    };

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(icon, color: scheme.onPrimaryContainer),
        ),
        title: Text(profile.name),
        subtitle: Text(
          '$label · ${profile.host}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          tooltip: tr('更多'),
          onSelected: (value) {
            switch (value) {
              case 'edit':
                onEdit();
              case 'test':
                onTest();
              case 'qr':
                onQr();
              case 'delete':
                onDelete();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text(tr('编辑'))),
            PopupMenuItem(value: 'test', child: Text(tr('测试连接'))),
            PopupMenuItem(value: 'qr', child: Text(tr('二维码'))),
            PopupMenuItem(value: 'delete', child: Text(tr('删除'))),
          ],
        ),
      ),
    );
  }
}

class _FavoriteCard extends StatelessWidget {
  const _FavoriteCard({
    required this.favorite,
    required this.subtitle,
    required this.onTap,
    required this.onRemove,
  });

  final Favorite favorite;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final remote = isRemotePath(favorite.path);
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Icon(
            remote ? Icons.cloud_rounded : Icons.star_rounded,
            color: scheme.onSecondaryContainer,
          ),
        ),
        title: Text(favorite.name),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: IconButton(
          tooltip: tr('移除收藏'),
          icon: const Icon(Icons.close_rounded),
          onPressed: onRemove,
        ),
      ),
    );
  }
}
