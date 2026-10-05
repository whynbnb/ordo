import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/ordo_exception.dart';
import '../services/ordo_service.dart';

/// 打开文件选择器，返回所选文件的绝对路径（取消返回 null）。
Future<String?> pickFile(BuildContext context, {String? initial}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(builder: (_) => _FilePicker(initial: initial)),
  );
}

class _FilePicker extends StatefulWidget {
  const _FilePicker({this.initial});

  final String? initial;

  @override
  State<_FilePicker> createState() => _FilePickerState();
}

class _FilePickerState extends State<_FilePicker> {
  final OrdoService _service = OrdoService.instance;

  late String _path;
  List<FileEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _path = widget.initial?.isNotEmpty == true ? widget.initial! : '/';
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _service.listDir(_path);
      if (!mounted) return;
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } on OrdoException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  void _enter(String path) {
    setState(() => _path = path);
    _load();
  }

  void _goUp() {
    final trimmed = _path.replaceAll(RegExp(r'/+$'), '');
    final index = trimmed.lastIndexOf('/');
    if (index <= 0) {
      _enter('/');
    } else {
      _enter(trimmed.substring(0, index));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('选择文件')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(
              _path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildList() {
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
    return ListView(
      children: [
        if (_path != '/')
          ListTile(
            leading: const Icon(Icons.arrow_upward_rounded),
            title: const Text('上级目录'),
            onTap: _goUp,
          ),
        for (final entry in _entries)
          ListTile(
            leading: Icon(
              entry.isDir
                  ? Icons.folder_rounded
                  : Icons.insert_drive_file_rounded,
              color: entry.isDir
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: entry.isDir ? const Icon(Icons.chevron_right_rounded) : null,
            onTap: () => entry.isDir
                ? _enter(entry.path)
                : Navigator.of(context).pop(entry.path),
          ),
      ],
    );
  }
}
