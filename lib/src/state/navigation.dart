import 'package:flutter/material.dart';

import '../core/format.dart';
import '../ui/browser_screen.dart';

/// 全局导航 key，供桌面快捷方式等外部入口跳转。
final GlobalKey<NavigatorState> ordoNavigatorKey = GlobalKey<NavigatorState>();

/// 打开某个路径（桌面快捷方式 / 冷启动）。
void openPathFromShortcut(String path) {
  if (path.isEmpty) return;
  final title = baseName(path);
  ordoNavigatorKey.currentState?.push(
    MaterialPageRoute<void>(
      builder: (_) =>
          BrowserScreen(path: path, title: title.isEmpty ? path : title),
    ),
  );
}
