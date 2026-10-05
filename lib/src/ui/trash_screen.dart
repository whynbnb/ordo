import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import 'dialogs.dart';
import '../i18n/i18n.dart';

/// 回收站：查看、恢复或彻底删除此前移入的文件。
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  final OrdoService _service = OrdoService.instance;

  List<TrashEntry> _entries = const [];
  bool _loading = true;
  String? _error;

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
      final entries = await _service.trashList();
      if (!mounted) return;
      setState(() {
        _entries = entries;
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

  Future<void> _restore(TrashEntry entry) async {
    try {
      final result = await _service.trashRestore([entry.id]);
      await _load();
      _snack(
        result.restored > 0 ? tr('已恢复「{p0}」', {'p0': entry.name}) : tr('恢复失败'),
        errors: result.errors,
      );
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _remove(TrashEntry entry) async {
    try {
      final result = await _service.trashRemove([entry.id]);
      await _load();
      _snack(
        result.deleted > 0 ? tr('已彻底删除「{p0}」', {'p0': entry.name}) : tr('删除失败'),
        errors: result.errors,
      );
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _empty() async {
    final confirmed = await showConfirmDialog(
      context,
      title: tr('清空回收站'),
      message: tr('将彻底删除回收站中的 {p0} 项，无法恢复。', {'p0': _entries.length}),
      confirmLabel: tr('清空'),
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      final deleted = await _service.trashEmpty();
      await _load();
      _snack(tr('已清空 {deleted} 项', {'deleted': deleted}));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('回收站')),
        actions: [
          IconButton(
            tooltip: tr('清空回收站'),
            icon: const Icon(Icons.delete_sweep_rounded),
            onPressed: _entries.isEmpty ? null : _empty,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.delete_outline_rounded,
              size: 56,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              tr('回收站是空的'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return ListTile(
          onTap: () => _restore(entry),
          leading: Icon(
            entry.isDir
                ? Icons.folder_rounded
                : Icons.insert_drive_file_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${entry.originalPath}\n'
            '${formatBytes(entry.size)} · ${formatDate(entry.deletedAt)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          isThreeLine: true,
          trailing: PopupMenuButton<String>(
            tooltip: tr('更多'),
            onSelected: (value) {
              if (value == 'restore') {
                _restore(entry);
              } else {
                _remove(entry);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'restore', child: Text(tr('恢复'))),
              PopupMenuItem(value: 'delete', child: Text(tr('彻底删除'))),
            ],
          ),
        );
      },
    );
  }
}
