import 'dart:io';

import 'package:flutter/material.dart';

import '../services/ordo_service.dart';
import '../services/platform_service.dart';
import 'home_screen.dart';

/// 启动检查：确认 Rust 核心可用、存储权限已授予。
class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> with WidgetsBindingObserver {
  bool _checking = true;
  bool _permissionGranted = false;
  String? _coreError;
  String? _version;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !_permissionGranted &&
        _coreError == null) {
      _refreshPermission();
    }
  }

  Future<void> _bootstrap() async {
    setState(() {
      _checking = true;
      _coreError = null;
    });

    try {
      final info = await OrdoService.instance.ping();
      _version = info['version']?.toString();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _coreError = '$error';
      });
      return;
    }

    final granted = await _hasPermission();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _permissionGranted = granted;
    });
  }

  Future<void> _refreshPermission() async {
    final granted = await _hasPermission();
    if (!mounted) return;
    setState(() => _permissionGranted = granted);
  }

  Future<bool> _hasPermission() async {
    if (!Platform.isAndroid) return true;
    return PlatformService.hasStoragePermission();
  }

  Future<void> _request() async {
    await PlatformService.requestStoragePermission();
    await _refreshPermission();
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_coreError != null) {
      return _CoreErrorScreen(message: _coreError!, onRetry: _bootstrap);
    }
    if (!_permissionGranted) {
      return _PermissionScreen(onRequest: _request);
    }
    return HomeScreen(version: _version);
  }
}

class _CoreErrorScreen extends StatelessWidget {
  const _CoreErrorScreen({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.memory_rounded, size: 56),
              const SizedBox(height: 16),
              Text(
                '无法加载 Rust 核心',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionScreen extends StatelessWidget {
  const _PermissionScreen({required this.onRequest});

  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.folder_shared_rounded,
                  size: 48,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 24),
              Text('需要存储权限', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(
                '安序需要「所有文件访问权限」来浏览和管理设备上的文件。'
                '所有读取与修改都由本地 Rust 核心完成，不会上传任何数据。',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onRequest,
                  child: const Text('前往授权'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
