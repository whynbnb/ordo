import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import 'directory_picker.dart';
import 'qr_dialog.dart';
import '../i18n/i18n.dart';
import 'snack.dart';

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

  List<ServerUser> _users = <ServerUser>[];
  ServerLog? _log;
  Timer? _logTimer;

  ServerStatus? _status;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _logTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && (_status?.running ?? false)) _refreshLog();
    });
  }

  @override
  void dispose() {
    _logTimer?.cancel();
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
        _users = List.of(config.users);
        _status = status;
        _busy = false;
      });
      await _refreshLog();
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
      users: _users,
    );
  }

  Future<void> _start() async {
    if (!_http && !_ftp) {
      _snack(tr('请至少启用一种服务器'));
      return;
    }
    if (_root.text.trim().isEmpty) {
      _snack(tr('请选择要共享的目录'));
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
      _snack(tr('服务器已启动'));
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(tr('启动失败：{error}', {'error': error}));
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
      _snack(tr('停止失败：{error}', {'error': error}));
    }
  }

  Future<void> _pickRoot() async {
    final chosen = await pickDirectory(context, initial: _root.text.trim());
    if (chosen != null) setState(() => _root.text = chosen);
  }

  Future<void> _refreshLog() async {
    try {
      final log = await _service.serverLog();
      if (!mounted) return;
      setState(() => _log = log);
    } catch (_) {
      // 忽略日志读取异常。
    }
  }

  Future<void> _clearLog() async {
    try {
      await _service.serverLogClear();
      await _refreshLog();
    } catch (error) {
      _snack(tr('清空失败：{error}', {'error': error}));
    }
  }

  Future<void> _editUser([int? index]) async {
    final existing = index == null ? null : _users[index];
    final result = await showDialog<ServerUser>(
      context: context,
      builder: (_) => _UserDialog(initial: existing),
    );
    if (result == null || !mounted) return;
    setState(() {
      final next = List<ServerUser>.of(_users);
      if (index == null) {
        next.add(result);
      } else {
        next[index] = result;
      }
      _users = next;
    });
  }

  void _removeUser(int index) {
    setState(() => _users = List<ServerUser>.of(_users)..removeAt(index));
  }

  void _snack(String message) {
    if (!mounted) return;
    showOrdoSnack(context, message);
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _snack(tr('已复制：{text}', {'text': text}));
  }

  @override
  Widget build(BuildContext context) {
    final running = _status?.running ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('文件服务器')),
        actions: [
          IconButton(
            tooltip: tr('刷新状态'),
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
                _section(tr('共享目录')),
                Card(
                  elevation: 0,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  child: ListTile(
                    leading: const Icon(Icons.folder_rounded),
                    title: Text(
                      _root.text.isEmpty ? tr('未选择') : _root.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: TextButton(
                      onPressed: _busy ? null : _pickRoot,
                      child: Text(tr('选择')),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _section(tr('协议')),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('HTTP / WebDAV'),
                  subtitle: Text(tr('浏览器访问，可映射为网络驱动器')),
                  value: _http,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _http = value),
                ),
                if (_http) _portField(_httpPort, tr('HTTP 端口'), tr('默认 8080')),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('FTP'),
                  subtitle: Text(tr('供 FTP 客户端 / 文件管理器连接')),
                  value: _ftp,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _ftp = value),
                ),
                if (_ftp) _portField(_ftpPort, tr('FTP 端口'), tr('默认 2121')),
                const SizedBox(height: 8),
                _section(tr('访问控制')),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('需要用户名与密码')),
                  value: _auth,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _auth = value),
                ),
                if (_auth) ...[
                  _textField(_username, tr('用户名')),
                  _textField(_password, tr('密码'), obscure: true),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('只读模式')),
                  subtitle: Text(tr('仅允许浏览与下载，禁止上传 / 删除')),
                  value: _readOnly,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _readOnly = value),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _section(tr('多用户'))),
                    TextButton.icon(
                      onPressed: _busy ? null : () => _editUser(),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: Text(tr('添加用户')),
                    ),
                  ],
                ),
                Text(
                  _users.isEmpty
                      ? tr('未配置多用户时，使用上方的单账号（若启用）。')
                      : tr('已启用多用户：上方单账号设置不再生效；每个账号可限定子目录与只读。'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                for (var i = 0; i < _users.length; i++)
                  Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(top: 8),
                    color: Theme.of(context).colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    child: ListTile(
                      leading: const Icon(Icons.person_rounded),
                      title: Text(_users[i].username),
                      subtitle: Text(
                        '${_users[i].path.isEmpty ? tr('根目录') : _users[i].path}'
                        '${_users[i].readOnly ? tr(' · 只读') : ''}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: tr('编辑'),
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: _busy ? null : () => _editUser(i),
                          ),
                          IconButton(
                            tooltip: tr('删除'),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                            ),
                            onPressed: _busy ? null : () => _removeUser(i),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy ? null : (running ? _stop : _start),
                  icon: Icon(
                    running
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline_rounded,
                  ),
                  label: Text(running ? tr('停止服务器') : tr('启动服务器')),
                ),
                const SizedBox(height: 12),
                Text(
                  tr('提示：其他设备需与本机处于同一局域网。FTP 为明文传输，请仅在可信网络中使用。'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (running) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: _section(tr('访问日志'))),
                      TextButton.icon(
                        onPressed: _refreshLog,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(tr('刷新')),
                      ),
                      IconButton(
                        tooltip: tr('清空'),
                        onPressed: _clearLog,
                        icon: const Icon(
                          Icons.cleaning_services_outlined,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                  if ((_log?.clients ?? const []).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final client in _log!.clients)
                            Chip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                '${client.protocol.toUpperCase()} '
                                '${client.address} · ${client.requests}',
                              ),
                            ),
                        ],
                      ),
                    ),
                  if ((_log?.entries ?? const []).isEmpty)
                    Text(
                      tr('暂无访问记录'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    for (final entry in _log!.entries.take(50))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Text(
                          entry.protocol.toUpperCase(),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        title: Text(
                          entry.path.isEmpty
                              ? entry.action
                              : '${entry.action} ${entry.path}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${entry.client} · ${formatDate(entry.time)} · '
                          '${entry.status}',
                        ),
                      ),
                ],
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
                  tr('正在运行'),
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (status.readOnly)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(tr('只读')),
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
              tr('本机地址：{p0}', {'p0': status.host}),
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
            tooltip: tr('二维码'),
            icon: const Icon(Icons.qr_code_rounded, size: 18),
            onPressed: () => showQrDialog(context, title: label, data: url),
          ),
          IconButton(
            tooltip: tr('复制'),
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

class _UserDialog extends StatefulWidget {
  const _UserDialog({this.initial});

  final ServerUser? initial;

  @override
  State<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<_UserDialog> {
  late final TextEditingController _username = TextEditingController(
    text: widget.initial?.username ?? '',
  );
  late final TextEditingController _password = TextEditingController(
    text: widget.initial?.password ?? '',
  );
  late final TextEditingController _path = TextEditingController(
    text: widget.initial?.path ?? '',
  );
  late bool _readOnly = widget.initial?.readOnly ?? false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _path.dispose();
    super.dispose();
  }

  void _submit() {
    final username = _username.text.trim();
    if (username.isEmpty || _password.text.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(tr('用户名与密码不能为空'))));
      return;
    }
    Navigator.pop(
      context,
      ServerUser(
        username: username,
        password: _password.text,
        path: _path.text.trim(),
        readOnly: _readOnly,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? tr('添加用户') : tr('编辑用户')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _username,
              decoration: InputDecoration(
                labelText: tr('用户名'),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: tr('密码'),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _path,
              decoration: InputDecoration(
                labelText: tr('限定子目录（可选）'),
                hintText: tr('相对共享根，如 Photos'),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(tr('该账号只读')),
              value: _readOnly,
              onChanged: (value) => setState(() => _readOnly = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('取消')),
        ),
        FilledButton(onPressed: _submit, child: Text(tr('确定'))),
      ],
    );
  }
}
