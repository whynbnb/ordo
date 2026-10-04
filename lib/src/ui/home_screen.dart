import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/ordo_exception.dart';
import '../services/ordo_service.dart';
import '../state/connections.dart';
import '../state/drop_controller.dart';
import '../state/favorites.dart';
import '../state/route_observer.dart';
import 'browser_screen.dart';
import 'connection_edit.dart';
import 'dialogs.dart';
import 'drop_overlay.dart';
import 'server_screen.dart';

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

  static const _quickCandidates = <_QuickFolder>[
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
    _connections.load();
    _favorites.loadIfNeeded();
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
    String path = '/storage/emulated/0';
    for (final root in _roots) {
      if (root.kind == 'internal') {
        path = root.path;
        break;
      }
    }
    DropController.instance.setActive(path, '内部存储');
  }

  @override
  void dispose() {
    ordoRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _connections.removeListener(_onStoreChanged);
    _favorites.removeListener(_onStoreChanged);
    super.dispose();
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

  void _openPath(String path, String title) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => BrowserScreen(path: path, title: title),
          ),
        )
        // 返回时静默刷新，及时反映已拔出的外部介质。
        .then((_) {
          if (mounted) _load(showSpinner: false);
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('安序'),
        actions: [
          IconButton(
            tooltip: '文件服务器',
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
            tooltip: '关于',
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: _showAbout,
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
                    child: const Text('重试'),
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
        _sectionTitle('存储'),
        const SizedBox(height: 8),
        if (_roots.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('未发现可用的存储卷')),
          )
        else
          for (final root in _roots) ...[
            _StorageCard(
              root: root,
              onTap: () => _openPath(root.path, root.name),
            ),
            const SizedBox(height: 12),
          ],
        if (_quickFolders.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionTitle('常用'),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.1,
            children: [
              for (final folder in _quickFolders)
                _QuickCard(
                  folder: folder,
                  onTap: () => _openPath(folder.path!, folder.label),
                ),
            ],
          ),
        ],
        if (_favorites.items.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionTitle('收藏'),
          const SizedBox(height: 8),
          for (final favorite in _favorites.items) ...[
            _FavoriteCard(
              favorite: favorite,
              onTap: () => _openPath(favorite.path, favorite.name),
              onRemove: () => _favorites.remove(favorite.path),
            ),
            const SizedBox(height: 10),
          ],
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _sectionTitle('网络位置')),
            TextButton.icon(
              onPressed: () => _editConnection(null),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('添加'),
            ),
          ],
        ),
        for (final profile in _connections.profiles) ...[
          _ConnectionCard(
            profile: profile,
            onTap: () => _openPath(profile.rootUri, profile.name),
            onEdit: () => _editConnection(profile),
            onTest: () => _testConnection(profile),
            onDelete: () => _deleteConnection(profile),
          ),
          const SizedBox(height: 10),
        ],
        if (_connections.profiles.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '添加 WebDAV / FTP / SMB 连接后可在此访问。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 24),
        Center(
          child: Text(
            '安序 Ordo${widget.version == null ? '' : ' · v${widget.version}'}',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      ],
    );
  }

  Future<void> _editConnection(ConnectionProfile? existing) async {
    final result = await showConnectionEditor(context, initial: existing);
    if (result == null || !mounted) return;
    try {
      await _connections.save(result);
      _snack('已保存「${result.name}」');
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _testConnection(ConnectionProfile profile) async {
    _snack('正在测试「${profile.name}」…');
    try {
      await _connections.test(profile);
      _snack('连接成功：${profile.name}');
    } catch (error) {
      _snack('连接失败：$error');
    }
  }

  Future<void> _deleteConnection(ConnectionProfile profile) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除连接',
      message: '确定删除「${profile.name}」吗？',
      confirmLabel: '删除',
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

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: '安序 Ordo',
      applicationVersion: widget.version == null
          ? '1.0.0'
          : 'v${widget.version}',
      applicationIcon: const Icon(Icons.folder_rounded, size: 40),
      children: const [
        Text(
          '一个使用 Flutter + Rust 构建的安卓文件管理器。'
          '所有文件操作均由本地 Rust 核心完成。',
        ),
      ],
    );
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
                          root.name,
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
                '已用 ${formatBytes(root.used)} / 共 ${formatBytes(root.total)}'
                '   可用 ${formatBytes(root.free)}',
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
                        '系统未向本应用开放该卷的访问权限',
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
            Text(folder.label, style: Theme.of(context).textTheme.bodyMedium),
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
    required this.onDelete,
  });

  final ConnectionProfile profile;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onTest;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, String label) = switch (profile.kind) {
      'smb' => (Icons.lan_rounded, 'SMB'),
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
          tooltip: '更多',
          onSelected: (value) {
            switch (value) {
              case 'edit':
                onEdit();
              case 'test':
                onTest();
              case 'delete':
                onDelete();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('编辑')),
            PopupMenuItem(value: 'test', child: Text('测试连接')),
            PopupMenuItem(value: 'delete', child: Text('删除')),
          ],
        ),
      ),
    );
  }
}

class _FavoriteCard extends StatelessWidget {
  const _FavoriteCard({
    required this.favorite,
    required this.onTap,
    required this.onRemove,
  });

  final Favorite favorite;
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
        subtitle: Text(
          favorite.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          tooltip: '移除收藏',
          icon: const Icon(Icons.close_rounded),
          onPressed: onRemove,
        ),
      ),
    );
  }
}
