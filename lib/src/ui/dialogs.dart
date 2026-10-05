import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import 'entry_visuals.dart';
import '../i18n/i18n.dart';

/// 文本输入对话框，用于新建 / 重命名。
Future<String?> showNameDialog(
  BuildContext context, {
  required String title,
  String initialText = '',
  String? hintText,
  String? confirmLabel,
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
          decoration: InputDecoration(hintText: hintText ?? tr('名称')),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(confirmLabel ?? tr('确定')),
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
  String? confirmLabel,
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
            child: Text(tr('取消')),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel ?? tr('确定')),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

Future<void> showDetailsSheet(BuildContext context, FileEntry entry) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _DetailsSheet(entry: entry),
  );
}

class _DetailsSheet extends StatefulWidget {
  const _DetailsSheet({required this.entry});

  final FileEntry entry;

  @override
  State<_DetailsSheet> createState() => _DetailsSheetState();
}

class _DetailsSheetState extends State<_DetailsSheet> {
  final OrdoService _service = OrdoService.instance;

  ({int size, int files, int dirs})? _dirInfo;
  bool _loadingDir = false;

  @override
  void initState() {
    super.initState();
    if (widget.entry.isDir) _computeDir();
  }

  Future<void> _computeDir() async {
    setState(() => _loadingDir = true);
    try {
      final info = await _service.dirSize(widget.entry.path);
      if (!mounted) return;
      setState(() {
        _dirInfo = info;
        _loadingDir = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingDir = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final scheme = Theme.of(context).colorScheme;
    final rows = <(String, String)>[
      (tr('名称'), entry.name),
      (tr('路径'), entry.path),
      (
        tr('类型'),
        entry.isDir
            ? tr('文件夹')
            : (entry.extension.isEmpty
                  ? tr('文件')
                  : tr('{p0} 文件', {'p0': entry.extension.toUpperCase()})),
      ),
      if (!entry.isDir && entry.extension.isNotEmpty)
        (tr('MIME 类型'), mimeOfExtension(entry.extension)),
      if (!entry.isDir) (tr('大小'), formatBytes(entry.size)),
      if (entry.isDir && _dirInfo != null) ...[
        (tr('大小'), formatBytes(_dirInfo!.size)),
        (
          tr('包含'),
          tr('{p0} 个文件 · {p1} 个文件夹', {
            'p0': _dirInfo!.files,
            'p1': _dirInfo!.dirs,
          }),
        ),
      ],
      (tr('修改时间'), formatDate(entry.modified)),
      (tr('创建时间'), formatDate(entry.created)),
      (tr('可读'), entry.readable ? tr('是') : tr('否')),
      (tr('可写'), entry.writable ? tr('是') : tr('否')),
      if (entry.isSymlink) (tr('符号链接'), tr('是')),
    ];

    return SafeArea(
      child: SingleChildScrollView(
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
                      tr('详细信息'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (entry.isDir && _loadingDir)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        tr('正在计算大小…'),
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
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
      ),
    );
  }
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
      ..showSnackBar(SnackBar(content: Text(tr('已复制'))));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('校验和')),
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
          child: Text(tr('关闭')),
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
                tooltip: tr('复制'),
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

/// 按需统计文件夹大小（计算全部由 Rust 完成）。
Future<void> showFolderSizeDialog(BuildContext context, FileEntry entry) {
  return showDialog<void>(
    context: context,
    builder: (_) => _FolderSizeDialog(entry: entry),
  );
}

class _FolderSizeDialog extends StatefulWidget {
  const _FolderSizeDialog({required this.entry});

  final FileEntry entry;

  @override
  State<_FolderSizeDialog> createState() => _FolderSizeDialogState();
}

class _FolderSizeDialogState extends State<_FolderSizeDialog> {
  final OrdoService _service = OrdoService.instance;

  bool _loading = true;
  String? _error;
  ({int size, int files, int dirs})? _result;

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
      final result = await _service.dirSize(widget.entry.path);
      if (!mounted) return;
      setState(() {
        _result = result;
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(
        widget.entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: _loading
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
                Text(
                  tr('共 {p0}', {'p0': formatBytes(_result!.size)}),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                Text(
                  tr('{p0} 个文件 · {p1} 个文件夹', {'p0': _result!.files, 'p1': _result!.dirs}),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
      actions: [
        TextButton(
          onPressed: _loading ? null : _compute,
          child: Text(tr('重新计算')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('关闭')),
        ),
      ],
    );
  }
}

/// 显示图片的 EXIF / 媒体信息（解析全部由 Rust 完成）。
Future<void> showMediaInfoDialog(BuildContext context, FileEntry entry) {
  return showDialog<void>(
    context: context,
    builder: (_) => _MediaInfoDialog(entry: entry),
  );
}

class _MediaInfoDialog extends StatefulWidget {
  const _MediaInfoDialog({required this.entry});

  final FileEntry entry;

  @override
  State<_MediaInfoDialog> createState() => _MediaInfoDialogState();
}

class _MediaInfoDialogState extends State<_MediaInfoDialog> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _info = const {};

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
      final info = await OrdoService.instance.mediaInfo(widget.entry.path);
      if (!mounted) return;
      setState(() {
        _info = info;
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

  List<(String, String)> get _rows {
    final rows = <(String, String)>[
      (tr('文件'), widget.entry.name),
      (
        tr('大小'),
        formatBytes((_info['size'] as num?)?.toInt() ?? widget.entry.size),
      ),
    ];
    final width = (_info['width'] as num?)?.toInt();
    final height = (_info['height'] as num?)?.toInt();
    if (width != null && height != null) {
      rows.add((tr('尺寸'), '$width × $height'));
    }
    void add(String key, String label) {
      final value = _info[key];
      if (value != null && '$value'.isNotEmpty) rows.add((label, '$value'));
    }

    add('date_taken', tr('拍摄时间'));
    add('camera', tr('相机'));
    add('orientation', tr('方向'));
    add('f_number', tr('光圈'));
    add('exposure_time', tr('曝光时间'));
    add('iso', 'ISO');
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(tr('媒体信息')),
      content: _loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          : _error != null
          ? Text(_error!)
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final row in _rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 72,
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
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('关闭')),
        ),
      ],
    );
  }
}
