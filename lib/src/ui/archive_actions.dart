import 'package:flutter/material.dart';

import '../services/ordo_service.dart';
import 'job_progress.dart';

/// 归档格式。
enum ArchiveFormat { zip, tar, tarGz }

extension ArchiveFormatInfo on ArchiveFormat {
  String get extension => switch (this) {
    ArchiveFormat.zip => 'zip',
    ArchiveFormat.tar => 'tar',
    ArchiveFormat.tarGz => 'tar.gz',
  };

  String get label => switch (this) {
    ArchiveFormat.zip => 'ZIP',
    ArchiveFormat.tar => 'TAR',
    ArchiveFormat.tarGz => 'TAR.GZ',
  };

  bool get supportsPassword => this == ArchiveFormat.zip;
}

/// 去掉归档扩展名，得到基础名称。
String archiveStem(String name) {
  final lower = name.toLowerCase();
  for (final suffix in ['.tar.gz', '.tgz', '.tar', '.zip']) {
    if (lower.endsWith(suffix)) {
      return name.substring(0, name.length - suffix.length);
    }
  }
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// 选择压缩格式。
Future<ArchiveFormat?> pickArchiveFormat(BuildContext context) {
  return showModalBottomSheet<ArchiveFormat>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final format in ArchiveFormat.values)
            ListTile(
              leading: Icon(
                format == ArchiveFormat.zip
                    ? Icons.folder_zip_rounded
                    : Icons.archive_rounded,
              ),
              title: Text(format.label),
              subtitle: Text(
                format == ArchiveFormat.zip ? '支持 AES 加密' : '不支持加密',
              ),
              onTap: () => Navigator.pop(sheetContext, format),
            ),
        ],
      ),
    ),
  );
}

/// 询问密码（用于已加密的压缩包）。
Future<String?> askArchivePassword(BuildContext context, String title) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(labelText: '密码'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, controller.text),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

/// 解压 / 提取，遇到加密压缩包会自动询问密码后重试。
Future<bool> runArchiveExtract(
  BuildContext context, {
  required String archivePath,
  required String dest,
  String? only,
}) async {
  var password = '';
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      await runWithJobProgress<void>(
        context,
        only == null ? '正在解压' : '正在提取',
        (jobId) => OrdoService.instance.archiveExtract(
          archivePath,
          dest,
          password: password,
          only: only,
          jobId: jobId,
        ),
      );
      return true;
    } catch (error) {
      final message = '$error';
      if (message.contains('需要密码') && context.mounted) {
        final input = await askArchivePassword(context, '压缩包已加密');
        if (input == null) return false;
        password = input;
        continue;
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      }
      return false;
    }
  }
  return false;
}

/// 压缩参数（名称与可选密码）。
typedef CompressRequest = ({String name, String password});

/// 压缩对话框：确认名称，ZIP 时可设置密码。
Future<CompressRequest?> showCompressDialog(
  BuildContext context, {
  required String defaultName,
  required bool allowPassword,
}) {
  return showDialog<CompressRequest>(
    context: context,
    builder: (_) => _CompressDialog(
      defaultName: defaultName,
      allowPassword: allowPassword,
    ),
  );
}

class _CompressDialog extends StatefulWidget {
  const _CompressDialog({
    required this.defaultName,
    required this.allowPassword,
  });

  final String defaultName;
  final bool allowPassword;

  @override
  State<_CompressDialog> createState() => _CompressDialogState();
}

class _CompressDialogState extends State<_CompressDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.defaultName,
  );
  final TextEditingController _passwordController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('压缩'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '文件名'),
            ),
            if (widget.allowPassword)
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码（可选）',
                  hintText: '留空则不加密',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, (
              name: name,
              password: widget.allowPassword ? _passwordController.text : '',
            ));
          },
          child: const Text('压缩'),
        ),
      ],
    );
  }
}
