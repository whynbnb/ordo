import 'package:flutter/foundation.dart';

import '../services/platform_service.dart';

/// 外部存储（U 盘 / 存储卡）插拔的全局事件源。
///
/// Android 原生层在检测到挂载 / 卸载后发送 `storageChanged`，这里只做去抖后的
/// 转发；真正的卷列表仍由 Rust 核心给出，界面监听 [revision] 即可刷新。
class StorageEvents {
  StorageEvents._();

  static final StorageEvents instance = StorageEvents._();

  /// 存储卷发生变化时自增，供页面刷新列表。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void register() {
    PlatformService.addStorageListener(_onChanged);
  }

  void _onChanged() {
    revision.value++;
  }
}
