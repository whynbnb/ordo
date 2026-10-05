import 'package:flutter/material.dart';

import '../core/models.dart';
import '../state/recent_store.dart';
import 'browser_screen.dart';
import 'open_entry.dart';
import '../i18n/i18n.dart';

/// 最近访问记录。
class RecentScreen extends StatefulWidget {
  const RecentScreen({super.key});

  @override
  State<RecentScreen> createState() => _RecentScreenState();
}

class _RecentScreenState extends State<RecentScreen> {
  final RecentStore _recent = RecentStore.instance;

  @override
  void initState() {
    super.initState();
    _recent.addListener(_onChanged);
    _recent.loadIfNeeded();
  }

  @override
  void dispose() {
    _recent.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _open(RecentItem item) async {
    if (item.isDir) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BrowserScreen(path: item.path, title: item.name),
        ),
      );
    } else {
      await openEntry(context, _asEntry(item));
    }
    if (mounted) setState(() {});
  }

  FileEntry _asEntry(RecentItem item) {
    return FileEntry(
      name: item.name,
      path: item.path,
      isDir: false,
      isSymlink: false,
      hidden: item.name.startsWith('.'),
      size: 0,
      modified: 0,
      created: 0,
      extension: _extensionOf(item.name),
      readable: true,
      writable: true,
    );
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('清空最近访问')),
        content: Text(tr('确定清空全部最近访问记录吗？')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr('清空')),
          ),
        ],
      ),
    );
    if (confirmed == true) await _recent.clear();
  }

  @override
  Widget build(BuildContext context) {
    final items = _recent.items;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('最近访问')),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              tooltip: tr('清空'),
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clear,
            ),
        ],
      ),
      body: items.isEmpty
          ? Center(
              child: Text(
                tr('暂无最近访问'),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          : ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  leading: Icon(
                    item.isDir
                        ? Icons.folder_rounded
                        : Icons.insert_drive_file_rounded,
                    color: item.isDir ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  title: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    item.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _relativeTime(item.time),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      IconButton(
                        tooltip: tr('删除'),
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => _recent.remove(item.path),
                      ),
                    ],
                  ),
                  onTap: () => _open(item),
                );
              },
            ),
    );
  }

  String _relativeTime(int millis) {
    if (millis <= 0) return '';
    final diff = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(millis),
    );
    if (diff.inMinutes < 1) return tr('刚刚');
    if (diff.inHours < 1) return tr('{p0} 分钟前', {'p0': diff.inMinutes});
    if (diff.inDays < 1) return tr('{p0} 小时前', {'p0': diff.inHours});
    if (diff.inDays < 30) return tr('{p0} 天前', {'p0': diff.inDays});
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1);
  }
}
