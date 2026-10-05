import 'package:flutter/material.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import 'archive_actions.dart';

/// 查看归档（ZIP / TAR / TAR.GZ）内容，可整体解压或单独提取条目。
class ArchiveViewerScreen extends StatefulWidget {
  const ArchiveViewerScreen({
    super.key,
    required this.entry,
    required this.parentDir,
  });

  final FileEntry entry;
  final String parentDir;

  @override
  State<ArchiveViewerScreen> createState() => _ArchiveViewerScreenState();
}

class _ArchiveViewerScreenState extends State<ArchiveViewerScreen> {
  final OrdoService _service = OrdoService.instance;

  List<ArchiveEntry> _entries = const [];
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
      final entries = await _service.archiveList(widget.entry.path);
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

  Future<void> _extractAll() async {
    final folder = archiveStem(widget.entry.name);
    final dest = joinPath(widget.parentDir, folder);
    final ok = await runArchiveExtract(
      context,
      archivePath: widget.entry.path,
      dest: dest,
    );
    if (!mounted || !ok) return;
    _snack('已解压到「$folder」');
    Navigator.of(context).pop();
  }

  Future<void> _extractEntry(ArchiveEntry entry) async {
    final ok = await runArchiveExtract(
      context,
      archivePath: widget.entry.path,
      dest: widget.parentDir,
      only: entry.name,
    );
    if (!mounted || !ok) return;
    _snack('已提取「${entry.name}」');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final label = archiveFormatLabel(widget.entry.name);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '解压到此处',
            icon: const Icon(Icons.unarchive_rounded),
            onPressed: _loading ? null : _extractAll,
          ),
        ],
      ),
      body: _buildBody(context, label),
    );
  }

  Widget _buildBody(BuildContext context, String? label) {
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
        child: Text(
          '空归档',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      itemCount: _entries.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) {
          return ListTile(
            dense: true,
            leading: const Icon(Icons.info_outline_rounded),
            title: Text('${_entries.length} 个条目${label == null ? '' : ' · $label'}'),
          );
        }
        final entry = _entries[index - 1];
        return ListTile(
          dense: true,
          onTap: () => _extractEntry(entry),
          leading: Icon(
            entry.isDir
                ? Icons.folder_rounded
                : Icons.insert_drive_file_outlined,
            color: scheme.primary,
          ),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: entry.isDir
              ? null
              : Text(
                  entry.encrypted
                      ? '${formatBytes(entry.size)} · 已加密'
                      : '${formatBytes(entry.size)}（压缩后 ${formatBytes(entry.compressed)}）',
                ),
          trailing: entry.isDir
              ? null
              : const Icon(Icons.download_rounded, size: 18),
        );
      },
    );
  }
}
