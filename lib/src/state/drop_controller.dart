import 'package:flutter/material.dart';

import '../services/ordo_service.dart';
import '../services/platform_service.dart';
import '../i18n/i18n.dart';

/// 跨应用拖放的全局状态与处理：把外部应用（如相册）拖入的文件导入当前目录。
class DropController {
  DropController._();

  static final DropController instance = DropController._();

  /// 供全局显示 SnackBar（没有当前页面上下文时使用）。
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// 是否有外部拖动正悬停在窗口上方。
  final ValueNotifier<bool> dragging = ValueNotifier<bool>(false);

  /// 导入完成后自增，供浏览页面刷新列表。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  String? _activePath;
  String _activeLabel = tr('内部存储');

  /// 当前可见浏览页面的目录；未设置时回退到内部存储根目录。
  String get activePath => _activePath ?? '/storage/emulated/0';
  String get activeLabel => _activeLabel;

  /// 由当前可见页面设置导入目标。
  void setActive(String? path, String? label) {
    _activePath = path;
    _activeLabel = (label == null || label.isEmpty) ? tr('内部存储') : label;
  }

  void register() {
    PlatformService.setDropHandler(
      onStarted: () {},
      onEntered: () => dragging.value = true,
      onExited: () => dragging.value = false,
      onDropped: _handleDrop,
    );
  }

  Future<void> _handleDrop(List<Map<String, dynamic>> items) async {
    dragging.value = false;
    final target = activePath;
    final label = activeLabel;
    if (items.isEmpty) {
      _snack(tr('没有识别到可导入的文件'));
      return;
    }

    var imported = 0;
    final errors = <String>[];
    for (final item in items) {
      final fd = (item['fd'] as num?)?.toInt();
      final name = item['name'] as String? ?? 'imported';
      if (fd == null) continue;
      try {
        await OrdoService.instance.importFd(
          fd: fd,
          destDir: target,
          name: name,
        );
        imported++;
      } catch (error) {
        errors.add('$error');
      }
    }

    if (imported > 0) revision.value++;
    _snack(
      imported > 0 ? tr('已导入 {imported} 个文件到「{label}」', {'imported': imported, 'label': label}) : tr('导入失败'),
      errors: errors,
    );
  }

  void _snack(String message, {List<String> errors = const []}) {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    final text = errors.isEmpty
        ? message
        : '$message\n${errors.take(3).join('\n')}';
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}
