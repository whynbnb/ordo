import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/ordo_exception.dart';
import '../services/ordo_service.dart';

/// 打开目录选择器，返回所选目录的绝对路径（取消返回 null）。
Future<String?> pickDirectory(BuildContext context, {String? initial}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      builder: (_) => _DirectoryPicker(initial: initial),
    ),
  );
}

class _DirectoryPicker extends StatefulWidget {
  const _DirectoryPicker({this.initial});

  final String? initial;

  @override
  State<_DirectoryPicker> createState() => _DirectoryPickerState();
}

class _DirectoryPickerState extends State<_DirectoryPicker> {
  final OrdoService _service = OrdoService.instance;

  late String _path;
  List<FileEntry> _dirs = const [];
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
      setState(() {
        _dirs = entries.where((e) => e.isDir).toList();
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
      appBar: AppBar(
        title: const Text('选择目录'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_path),
            child: const Text('选择'),
          ),
        ],
      ),
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
        for (final dir in _dirs)
          ListTile(
            leading: Icon(
              Icons.folder_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(dir.name),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _enter(dir.path),
          ),
        if (_dirs.isEmpty && _path == '/')
          const ListTile(title: Text('没有可进入的子目录')),
      ],
    );
  }
}
