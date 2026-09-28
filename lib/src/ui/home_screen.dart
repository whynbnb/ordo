import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/ordo_exception.dart';
import '../services/ordo_service.dart';
import 'browser_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.version});

  final String? version;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final OrdoService _service = OrdoService.instance;

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
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
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
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  void _openPath(String path, String title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(path: path, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('安序'),
        actions: [
          IconButton(
            tooltip: '关于',
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: _showAbout,
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _buildBody()),
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
                  FilledButton.tonal(onPressed: _load, child: const Text('重试')),
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
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    root.removable
                        ? Icons.sd_card_rounded
                        : Icons.smartphone_rounded,
                    color: scheme.primary,
                  ),
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
