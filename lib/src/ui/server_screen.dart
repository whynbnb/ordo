import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../services/ordo_service.dart';
import 'directory_picker.dart';
import 'qr_dialog.dart';

/// 在本机开启 HTTP/WebDAV 与 FTP 服务器，供同一局域网内的其他设备访问。
class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key});

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  final OrdoService _service = OrdoService.instance;

  final TextEditingController _root = TextEditingController();
  final TextEditingController _httpPort = TextEditingController();
  final TextEditingController _ftpPort = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  bool _http = true;
  bool _ftp = false;
  bool _auth = false;
  bool _readOnly = false;

  ServerStatus? _status;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _root.dispose();
    _httpPort.dispose();
    _ftpPort.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final config = await _service.serverLoadConfig();
      final status = await _service.serverStatus();
      if (!mounted) return;
      setState(() {
        _root.text = config.root.isEmpty ? '/storage/emulated/0' : config.root;
        _http = config.http;
        _ftp = config.ftp;
        _httpPort.text = (config.httpPort == 0 ? 8080 : config.httpPort)
            .toString();
        _ftpPort.text = (config.ftpPort == 0 ? 2121 : config.ftpPort)
            .toString();
        _auth = config.auth;
        _username.text = config.username;
        _password.text = config.password;
        _readOnly = config.readOnly;
        _status = status;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  ServerConfig _collect() {
    return ServerConfig(
      root: _root.text.trim(),
      http: _http,
      httpPort: int.tryParse(_httpPort.text.trim()) ?? 0,
      ftp: _ftp,
      ftpPort: int.tryParse(_ftpPort.text.trim()) ?? 0,
      auth: _auth,
      username: _username.text.trim(),
      password: _password.text,
      readOnly: _readOnly,
    );
  }

  Future<void> _start() async {
    if (!_http && !_ftp) {
      _snack('请至少启用一种服务器');
      return;
    }
    if (_root.text.trim().isEmpty) {
      _snack('请选择要共享的目录');
      return;
    }
    setState(() => _busy = true);
    try {
      final config = _collect();
      await _service.serverSaveConfig(config);
      final status = await _service.serverStart(config);
      if (!mounted) return;
      setState(() {
        _status = status;
        _busy = false;
      });
      _snack('服务器已启动');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('启动失败：$error');
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      final status = await _service.serverStop();
      if (!mounted) return;
      setState(() {
        _status = status;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('停止失败：$error');
    }
  }

  Future<void> _pickRoot() async {
    final chosen = await pickDirectory(context, initial: _root.text.trim());
    if (chosen != null) setState(() => _root.text = chosen);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _snack('已复制：$text');
  }

  @override
  Widget build(BuildContext context) {
    final running = _status?.running ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('文件服务器'),
        actions: [
          IconButton(
            tooltip: '刷新状态',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _busy && _status == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (running) _statusCard(context, _status!),
                _section('共享目录'),
                Card(
                  elevation: 0,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  child: ListTile(
                    leading: const Icon(Icons.folder_rounded),
                    title: Text(
                      _root.text.isEmpty ? '未选择' : _root.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: TextButton(
                      onPressed: _busy ? null : _pickRoot,
                      child: const Text('选择'),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _section('协议'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('HTTP / WebDAV'),
                  subtitle: const Text('浏览器访问，可映射为网络驱动器'),
                  value: _http,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _http = value),
                ),
                if (_http) _portField(_httpPort, 'HTTP 端口', '默认 8080'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('FTP'),
                  subtitle: const Text('供 FTP 客户端 / 文件管理器连接'),
                  value: _ftp,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _ftp = value),
                ),
                if (_ftp) _portField(_ftpPort, 'FTP 端口', '默认 2121'),
                const SizedBox(height: 8),
                _section('访问控制'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('需要用户名与密码'),
                  value: _auth,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _auth = value),
                ),
                if (_auth) ...[
                  _textField(_username, '用户名'),
                  _textField(_password, '密码', obscure: true),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('只读模式'),
                  subtitle: const Text('仅允许浏览与下载，禁止上传 / 删除'),
                  value: _readOnly,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _readOnly = value),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy ? null : (running ? _stop : _start),
                  icon: Icon(
                    running
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline_rounded,
                  ),
                  label: Text(running ? '停止服务器' : '启动服务器'),
                ),
                const SizedBox(height: 12),
                Text(
                  '提示：其他设备需与本机处于同一局域网。'
                  'FTP 为明文传输，请仅在可信网络中使用。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _statusCard(BuildContext context, ServerStatus status) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.primaryContainer.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle_rounded, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  '正在运行',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (status.readOnly)
                  const Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('只读'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (status.httpUrl != null)
              _urlRow(
                context,
                icon: Icons.cloud_rounded,
                label: 'HTTP / WebDAV',
                url: status.httpUrl!,
              ),
            if (status.ftpUrl != null)
              _urlRow(
                context,
                icon: Icons.cloud_upload_rounded,
                label: 'FTP',
                url: status.auth
                    ? status.ftpUrl!.replaceFirst(
                        'ftp://',
                        'ftp://${_username.text}@',
                      )
                    : status.ftpUrl!,
              ),
            const SizedBox(height: 4),
            Text(
              '本机地址：${status.host}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _urlRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String url,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.labelMedium),
                SelectableText(url),
              ],
            ),
          ),
          IconButton(
            tooltip: '二维码',
            icon: const Icon(Icons.qr_code_rounded, size: 18),
            onPressed: () => showQrDialog(context, title: label, data: url),
          ),
          IconButton(
            tooltip: '复制',
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: () => _copy(url),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _portField(
    TextEditingController controller,
    String label,
    String hint,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        enabled: !_busy,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}
