import 'package:flutter/material.dart';

import '../core/file_types.dart';
import '../core/models.dart';
import '../services/platform_service.dart';
import 'browser_screen.dart';
import 'viewer_screen.dart';

/// 打开一个条目：文件夹进入浏览，文本 / 图片在应用内预览，其余交给系统。
Future<void> openEntry(
  BuildContext context,
  FileEntry entry, {
  VoidCallback? onReturn,
}) async {
  if (entry.isDir) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(path: entry.path, title: entry.name),
      ),
    );
    onReturn?.call();
    return;
  }

  if (isTextExtension(entry.extension) || isImageExtension(entry.extension)) {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => ViewerScreen(entry: entry)));
    return;
  }

  final ok = await PlatformService.openFile(
    entry.path,
    mime: mimeOfExtension(entry.extension),
  );
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('没有找到可以打开此文件的应用')));
  }
}
