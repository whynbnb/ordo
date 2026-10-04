import 'package:flutter/material.dart';

import 'src/state/drop_controller.dart';
import 'src/state/route_observer.dart';
import 'src/ui/startup_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 注册跨应用拖放（把外部文件拖入安序）。
  DropController.instance.register();
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
