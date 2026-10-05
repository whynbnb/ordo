import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import 'directory_picker.dart';

/// 隐私空间：文件存放在应用私有目录，常规文件浏览器中不可见。
class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final OrdoService _service = OrdoService.instance;

  List<FileEntry> _items = const [];
  final Set<String> _selected = {};
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final items = await _service.vaultList();
      if (!mounted) return;
      setState(() {
        _items = items;
        _selected.removeWhere(
          (name) => !items.any((item) => item.name == name),
        );
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  void _toggle(String name) {
    setState(() {
      if (!_selected.add(name)) _selected.remove(name);
    });
  }

  Future<void> _restore() async {
    if (_selected.isEmpty) return;
    final dest = await pickDirectory(context, initial: '/storage/emulated/0');
    if (dest == null || !mounted) return;
    try {
      final result = await _service.vaultRestore(_selected.toList(), dest);
      _snack('已还原 ${result.count} 项', errors: result.errors);
      await _load();
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _delete() async {
    if (_selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('彻底删除'),
        content: Text('将覆盖写入后删除 ${_selected.length} 项，无法恢复。是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final result = await _service.vaultDelete(_selected.toList());
      _snack('已删除 ${result.deleted} 项', errors: result.errors);
      await _load();
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
        title: const Text('隐私空间'),
        actions: [
          IconButton(
            tooltip: '还原到…',
            onPressed: _selected.isEmpty ? null : _restore,
            icon: const Icon(Icons.unarchive_outlined),
          ),
          IconButton(
            tooltip: '彻底删除',
            onPressed: _selected.isEmpty ? null : _delete,
            icon: const Icon(Icons.delete_forever_outlined),
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    '文件保存在应用私有目录，其它应用与文件管理器无法直接访问。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: _items.isEmpty
                      ? Center(
                          child: Text(
                            '隐私空间为空',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (context, index) {
                            final entry = _items[index];
                            final name = entry.name;
                            return CheckboxListTile(
                              value: _selected.contains(name),
                              onChanged: (_) => _toggle(name),
                              secondary: Icon(
                                entry.isDir
                                    ? Icons.folder_rounded
                                    : Icons.description_outlined,
                              ),
                              title: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                entry.isDir
                                    ? '文件夹'
                                    : '${formatBytes(entry.size)} · '
                                          '${formatDate(entry.modified)}',
                              ),
                            );
                          },
                        ),
                ),
                if (_items.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: () => setState(() {
                            if (_selected.length == _items.length) {
                              _selected.clear();
                            } else {
                              _selected
                                ..clear()
                                ..addAll(_items.map((item) => item.name));
                            }
                          }),
                          child: Text(
                            _selected.length == _items.length ? '取消全选' : '全选',
                          ),
                        ),
                        const Spacer(),
                        Text('已选 ${_selected.length} 项'),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
