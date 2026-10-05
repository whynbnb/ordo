import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import 'entry_visuals.dart';

/// 文本输入对话框，用于新建 / 重命名。
Future<String?> showNameDialog(
  BuildContext context, {
  required String title,
  String initialText = '',
  String hintText = '名称',
  String confirmLabel = '确定',
}) {
  final controller = TextEditingController(text: initialText);
  return showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: hintText),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
}

Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确定',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

Future<void> showDetailsSheet(BuildContext context, FileEntry entry) {
  final scheme = Theme.of(context).colorScheme;
  final rows = <(String, String)>[
    ('名称', entry.name),
    ('路径', entry.path),
    (
      '类型',
      entry.isDir
          ? '文件夹'
          : (entry.extension.isEmpty
                ? '文件'
                : '${entry.extension.toUpperCase()} 文件'),
    ),
    if (!entry.isDir) ('大小', formatBytes(entry.size)),
    ('修改时间', formatDate(entry.modified)),
    ('创建时间', formatDate(entry.created)),
    ('可读', entry.readable ? '是' : '否'),
    ('可写', entry.writable ? '是' : '否'),
    if (entry.isSymlink) ('符号链接', '是'),
  ];

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    iconForEntry(entry),
                    color: colorForEntry(entry, scheme),
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '详细信息',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 88,
                        child: Text(
                          row.$1,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      Expanded(child: SelectableText(row.$2)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// 显示文件的 SHA-256 与 MD5 校验和（计算全部由 Rust 完成）。
Future<void> showHashDialog(BuildContext context, FileEntry entry) {
  return showDialog<void>(
    context: context,
    builder: (_) => _HashDialog(entry: entry),
  );
}

class _HashDialog extends StatefulWidget {
  const _HashDialog({required this.entry});

  final FileEntry entry;

  @override
  State<_HashDialog> createState() => _HashDialogState();
}

class _HashDialogState extends State<_HashDialog> {
  final OrdoService _service = OrdoService.instance;

  bool _loading = true;
  String? _error;
  ({String algorithm, String hash, int size})? _sha256;
  ({String algorithm, String hash, int size})? _md5;

  @override
  void initState() {
    super.initState();
    _compute();
  }

  Future<void> _compute() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sha = await _service.hash(widget.entry.path, algorithm: 'sha256');
      final md5 = await _service.hash(widget.entry.path, algorithm: 'md5');
      if (!mounted) return;
      setState(() {
        _sha256 = sha;
        _md5 = md5;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  void _copy(String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已复制')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('校验和'),
      content: SizedBox(
        width: 360,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            : _error != null
            ? Text(_error!)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _hashRow('SHA-256', _sha256),
                  const SizedBox(height: 16),
                  _hashRow('MD5', _md5),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _hashRow(
    String label,
    ({String algorithm, String hash, int size})? value,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            if (value != null)
              IconButton(
                tooltip: '复制',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy_rounded, size: 18),
                onPressed: () => _copy(value.hash),
              ),
          ],
        ),
        if (value == null)
          const Text('—')
        else
          SelectableText(
            value.hash,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
