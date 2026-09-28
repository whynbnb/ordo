import 'package:flutter/material.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import '../services/platform_service.dart';
import 'browser_screen.dart';
import 'viewer_screen.dart';

/// 打开一个条目：文件夹进入浏览，文本 / 图片在应用内预览，其余交给系统。
///
/// 远程文件会先由 Rust 核心下载到本地缓存，再交给系统应用打开。
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

  if (isRemotePath(entry.path)) {
    try {
      final cached = await OrdoService.instance.downloadToCache(entry.path);
      final ok = await PlatformService.openFile(
        cached.path,
        mime: mimeOfExtension(entry.extension),
      );
      if (!ok && context.mounted) {
        _snack(context, '没有找到可以打开此文件的应用');
      }
    } catch (error) {
      if (context.mounted) _snack(context, '打开失败：$error');
    }
    return;
  }

  final ok = await PlatformService.openFile(
    entry.path,
    mime: mimeOfExtension(entry.extension),
  );
  if (!ok && context.mounted) {
    _snack(context, '没有找到可以打开此文件的应用');
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
