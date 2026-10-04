import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import 'job_progress.dart';

/// 查看 ZIP 内容，并可一键解压到同级目录。
class ZipViewerScreen extends StatefulWidget {
  const ZipViewerScreen({
    super.key,
    required this.entry,
    required this.parentDir,
  });

  final FileEntry entry;
  final String parentDir;

  @override
  State<ZipViewerScreen> createState() => _ZipViewerScreenState();
}

class _ZipViewerScreenState extends State<ZipViewerScreen> {
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
      final entries = await _service.zipList(widget.entry.path);
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

  Future<void> _extract() async {
    final folder = _stem(widget.entry.name);
    final dest = joinPath(widget.parentDir, folder);
    try {
      await runWithJobProgress<void>(
        context,
        '正在解压',
        (jobId) => _service.zipExtract(widget.entry.path, dest, jobId: jobId),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('已解压到「$folder」')));
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  String _stem(String path) {
    final base = path.replaceAll(RegExp(r'/+$'), '').split('/').last;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  @override
  Widget build(BuildContext context) {
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
            onPressed: _loading ? null : _extract,
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
    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return ListTile(
          dense: true,
          leading: Icon(
            entry.isDir
                ? Icons.folder_rounded
                : Icons.insert_drive_file_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: entry.isDir
              ? null
              : Text(
                  '${formatBytes(entry.size)}（压缩后 ${formatBytes(entry.compressed)}）',
                ),
        );
      },
    );
  }
}
