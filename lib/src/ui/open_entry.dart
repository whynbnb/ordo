import 'package:flutter/material.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import '../services/platform_service.dart';
import '../state/prefs_store.dart';
import '../state/recent_store.dart';
import 'browser_screen.dart';
import 'viewer_screen.dart';

/// 打开一个条目：文件夹进入浏览；图片 / 音频 / 文本在应用内预览；其余交给系统。
///
/// 远程文件会先由 Rust 核心下载到本地缓存，再交给系统应用打开。
Future<void> openEntry(
  BuildContext context,
  FileEntry entry, {
  VoidCallback? onReturn,
}) async {
  if (entry.isDir) {
    RecentStore.instance.record(entry.path, entry.name, true);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(path: entry.path, title: entry.name),
      ),
    );
    onReturn?.call();
    return;
  }

  RecentStore.instance.record(entry.path, entry.name, false);
  if (isPreviewableExtension(entry.extension)) {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => ViewerScreen(entry: entry)));
    onReturn?.call();
    return;
  }

  await openWithDefault(context, entry);
}

/// 交给外部应用打开：若该类型设置了默认应用则直接跳转，否则弹出选择器。
Future<void> openWithDefault(BuildContext context, FileEntry entry) async {
  var path = entry.path;
  if (isRemotePath(path)) {
    try {
      final cached = await OrdoService.instance.downloadToCache(path);
      path = cached.path;
    } catch (error) {
      if (context.mounted) _snack(context, '打开失败：$error');
      return;
    }
  }

  await PrefsStore.instance.loadIfNeeded();
  final target = PrefsStore.instance.targetFor(entry.extension);
  final ok = await PlatformService.openFile(
    path,
    mime: mimeOfExtension(entry.extension),
    package: target?.package,
    activity: target?.activity,
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
