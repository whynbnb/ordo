import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
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
