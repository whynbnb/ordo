import 'package:flutter/material.dart';

import 'src/services/platform_service.dart';
import 'src/state/drop_controller.dart';
import 'src/state/navigation.dart';
import 'src/state/route_observer.dart';
import 'src/state/storage_events.dart';
import 'src/ui/startup_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 注册跨应用拖放（把外部文件拖入安序）。
  DropController.instance.register();
  // 注册外部存储插拔事件（U 盘 / 存储卡热插拔）。
  StorageEvents.instance.register();
  // 桌面快捷方式打开指定路径。
  PlatformService.setOpenPathHandler(openPathFromShortcut);
  runApp(const OrdoApp());
}

class OrdoApp extends StatelessWidget {
  const OrdoApp({super.key});

  static const Color _seed = Color(0xFF3D5AFE);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '安序',
      debugShowCheckedModeBanner: false,
      navigatorKey: ordoNavigatorKey,
      scaffoldMessengerKey: DropController.messengerKey,
      navigatorObservers: [ordoRouteObserver],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _seed),
        appBarTheme: const AppBarTheme(centerTitle: false),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(centerTitle: false),
      ),
      home: const StartupGate(),
    );
  }
}
