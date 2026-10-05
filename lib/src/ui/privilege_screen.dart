import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../state/privilege_store.dart';

/// 权限模式设置：Root / Shizuku /（后续）ADB。
class PrivilegeScreen extends StatefulWidget {
  const PrivilegeScreen({super.key});

  @override
  State<PrivilegeScreen> createState() => _PrivilegeScreenState();
}

class _PrivilegeScreenState extends State<PrivilegeScreen> {
  final PrivilegeStore _store = PrivilegeStore.instance;

  @override
  void initState() {
    super.initState();
    _store.detect();
  }

  Future<void> _select(String mode) async {
    if (_store.busy) return;
    if (mode == 'off') {
      await _store.deactivate();
      return;
    }
    if (mode == 'shizuku' && !_store.shizukuGranted) {
      final granted = await _store.requestShizuku();
      if (!granted) {
        if (mounted) {
          _snack(tr('请先启动并授权 Shizuku'));
        }
        return;
      }
    }
    final ok = await _store.activate(mode);
    if (!ok && mounted && _store.error != null) {
      _snack(tr('启用失败：{p0}', {'p0': trError(_store.error ?? '')}));
    }
  }

  Future<void> _selectAdb() async {
    if (_store.mode == 'adb' && _store.active) return;
    final enable = await showDialog<bool>(
      context: context,
      builder: (_) => _AdbPairDialog(store: _store),
    );
    if (enable != true || !mounted) return;
    final ok = await _store.activate('adb');
    if (!ok && mounted && _store.error != null) {
      _snack(tr('启用失败：{p0}', {'p0': trError(_store.error ?? '')}));
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('权限模式')),
        actions: [
          IconButton(
            tooltip: tr('重新检测'),
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _store.busy ? null : _store.detect,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          final scheme = Theme.of(context).colorScheme;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                tr('用于访问系统限制的目录（如 Android/data、Android/obb）；需要 Root 或 Shizuku。'),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              if (_store.busy) const LinearProgressIndicator(),
              _modeTile(
                mode: 'off',
                title: tr('不使用'),
                subtitle: tr('仅访问常规存储，不使用高权限。'),
                available: true,
              ),
              _modeTile(
                mode: 'root',
                title: 'Root',
                subtitle: _store.rootAvailable
                    ? tr('可访问全部文件，包括其它应用的私有数据。')
                    : tr('未检测到 Root。'),
                available: _store.rootAvailable,
              ),
              _modeTile(
                mode: 'shizuku',
                title: 'Shizuku',
                subtitle: _shizukuSubtitle(),
                available: _store.shizukuAvailable,
              ),
              _modeTile(
                mode: 'adb',
                title: 'ADB',
                subtitle: _store.adbAvailable
                    ? tr('通过无线调试直接连接，能力与 Shizuku 相同。')
                    : tr('未开启无线调试。'),
                available: _store.adbAvailable,
                onTap: _selectAdb,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _modeTile({
    required String mode,
    required String title,
    required String subtitle,
    required bool available,
    VoidCallback? onTap,
  }) {
    final selected = _store.mode == mode && (mode == 'off' || _store.active);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        enabled: available && !_store.busy,
        leading: Icon(
          selected
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_unchecked_rounded,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: mode != 'off' && _store.active && selected
            ? Icon(Icons.check_circle_rounded, color: scheme.primary)
            : null,
        onTap: available ? (onTap ?? () => _select(mode)) : null,
      ),
    );
  }

  String _shizukuSubtitle() {
    if (!_store.shizukuAvailable) return tr('Shizuku 未运行。');
    if (!_store.shizukuGranted) return tr('Shizuku 已运行，点击以请求授权。');
    return tr('可访问 Android/data 与 Android/obb。');
  }
}

/// ADB 配对对话框：填写无线调试的配对端口与验证码。
class _AdbPairDialog extends StatefulWidget {
  const _AdbPairDialog({required this.store});

  final PrivilegeStore store;

  @override
  State<_AdbPairDialog> createState() => _AdbPairDialogState();
}

class _AdbPairDialogState extends State<_AdbPairDialog> {
  final TextEditingController _host = TextEditingController();
  final TextEditingController _port = TextEditingController();
  final TextEditingController _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final host = widget.store.hostIp;
    if (host != null && host.isNotEmpty) {
      _host.text = host;
    }
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final port = int.tryParse(_port.text.trim());
    if (_host.text.trim().isEmpty || port == null || _code.text.trim().isEmpty) {
      setState(() => _error = tr('请填写主机、配对端口与验证码'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.store.pairAdb(
      host: _host.text.trim(),
      port: port,
      code: _code.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = tr('配对失败，请检查端口与验证码');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('ADB 配对')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('在「开发者选项 → 无线调试 → 使用配对码配对设备」中查看主机、配对端口与验证码。'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _host,
              decoration: InputDecoration(labelText: tr('主机')),
            ),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('配对端口')),
            ),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('验证码')),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(tr('取消')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(true),
          child: Text(tr('已配对，直接启用')),
        ),
        FilledButton(
          onPressed: _busy ? null : _pair,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('配对并启用')),
        ),
      ],
    );
  }
}
