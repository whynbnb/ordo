import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'src/services/ordo_service.dart';
import 'src/services/platform_service.dart';
import 'src/state/drop_controller.dart';
import 'src/state/navigation.dart';
import 'src/state/route_observer.dart';
import 'src/state/storage_events.dart';
import 'src/state/theme_store.dart';
import 'src/ui/startup_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 注册跨应用拖放（把外部文件拖入安序）。
  DropController.instance.register();
  // 注册外部存储插拔事件（U 盘 / 存储卡热插拔）。
  StorageEvents.instance.register();
  // 桌面快捷方式打开指定路径。
  PlatformService.setOpenPathHandler(openPathFromShortcut);
  // 载入主题偏好（异步，加载完成后重建界面）。
  ThemeStore.instance.load();

  // 记录 Flutter 与 Dart 未捕获错误，便于在设置中导出排查。
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    OrdoService.instance.crashAppend(
      'FLUTTER: ${details.exceptionAsString()}\n${details.stack ?? ''}',
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    OrdoService.instance.crashAppend('DART: $error\n$stack');
    return true;
  };

  runZonedGuarded(
    () => runApp(const OrdoApp()),
    (error, stack) {
      OrdoService.instance.crashAppend('ZONE: $error\n$stack');
    },
  );
}

class OrdoApp extends StatelessWidget {
  const OrdoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeStore.instance,
      builder: (context, _) {
        final store = ThemeStore.instance;
        return MaterialApp(
          title: '安序',
          debugShowCheckedModeBanner: false,
          navigatorKey: ordoNavigatorKey,
          scaffoldMessengerKey: DropController.messengerKey,
          navigatorObservers: [ordoRouteObserver],
          theme: _buildTheme(store.seed, Brightness.light),
          darkTheme: store.isBlack
              ? _buildBlackTheme(store.seed)
              : _buildTheme(store.seed, Brightness.dark),
          themeMode: store.materialThemeMode,
          home: const StartupGate(),
        );
      },
    );
  }

  ThemeData _buildTheme(Color seed, Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: brightness,
      ),
      appBarTheme: const AppBarTheme(centerTitle: false),
    );
  }

  ThemeData _buildBlackTheme(Color seed) {
    final base = _buildTheme(seed, Brightness.dark);
    final scheme = base.colorScheme.copyWith(
      surface: Colors.black,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xFF0A0A0A),
      surfaceContainer: const Color(0xFF0E0E0E),
      surfaceContainerHigh: const Color(0xFF141414),
      surfaceContainerHighest: const Color(0xFF1A1A1A),
    );
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.black,
      canvasColor: Colors.black,
      dividerColor: const Color(0xFF222222),
    );
  }
}
