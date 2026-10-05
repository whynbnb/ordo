import 'package:flutter/material.dart';

import '../core/models.dart';
import '../i18n/i18n.dart';

/// 打开连接编辑器；返回编辑后的配置，取消则返回 null。
Future<ConnectionProfile?> showConnectionEditor(
  BuildContext context, {
  ConnectionProfile? initial,
}) {
  return Navigator.of(context).push<ConnectionProfile>(
    MaterialPageRoute<ConnectionProfile>(
      builder: (_) => _ConnectionEditScreen(initial: initial),
    ),
  );
}

class _ConnectionEditScreen extends StatefulWidget {
  const _ConnectionEditScreen({this.initial});

  final ConnectionProfile? initial;

  @override
  State<_ConnectionEditScreen> createState() => _ConnectionEditScreenState();
}

class _ConnectionEditScreenState extends State<_ConnectionEditScreen> {
  late String _kind;
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _basePath;
  late final TextEditingController _share;
  late final TextEditingController _domain;
  late bool _secure;
  late bool _insecureTls;

  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial ?? ConnectionProfile.empty;
    _kind = initial.kind;
    _name = TextEditingController(text: initial.name);
    _host = TextEditingController(text: initial.host);
    _port = TextEditingController(
      text: initial.port == 0 ? '' : initial.port.toString(),
    );
    _username = TextEditingController(text: initial.username);
    _password = TextEditingController(text: initial.password);
    _basePath = TextEditingController(text: initial.basePath);
    _share = TextEditingController(text: initial.share);
    _domain = TextEditingController(text: initial.domain);
    _secure = initial.secure;
    _insecureTls = initial.insecureTls;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _basePath.dispose();
    _share.dispose();
    _domain.dispose();
    super.dispose();
  }

  String get _hostHint => switch (_kind) {
    'webdav' => tr('例如 dav.example.com 或 https://dav.example.com/dav'),
    'smb' => tr('例如 192.168.1.10'),
    'sftp' => tr('例如 sftp.example.com'),
    _ => tr('例如 ftp.example.com'),
  };

  String get _portHint => switch (_kind) {
    'webdav' => tr('443 / 80（留空自动）'),
    'smb' => tr('445（留空自动）'),
    'sftp' => tr('22（留空自动）'),
    _ => tr('21（留空自动）'),
  };

  void _submit() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = tr('请填写服务器地址'));
      return;
    }
    final initial = widget.initial ?? ConnectionProfile.empty;
    final profile = initial.copyWith(
      name: _name.text.trim().isEmpty ? host : _name.text.trim(),
      kind: _kind,
      host: host,
      port: int.tryParse(_port.text.trim()) ?? 0,
      username: _username.text,
      password: _password.text,
      basePath: _basePath.text.trim(),
      share: _share.text.trim(),
      domain: _domain.text.trim(),
      secure: _secure,
      insecureTls: _insecureTls,
    );
    Navigator.of(context).pop(profile);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? tr('添加连接') : tr('编辑连接')),
        actions: [TextButton(onPressed: _submit, child: Text(tr('保存')))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'webdav', label: Text('WebDAV')),
                ButtonSegment(value: 'ftp', label: Text('FTP')),
                ButtonSegment(value: 'sftp', label: Text('SFTP')),
                ButtonSegment(value: 'smb', label: Text('SMB')),
              ],
              selected: {_kind},
              onSelectionChanged: (value) =>
                  setState(() => _kind = value.first),
            ),
          ),
          const SizedBox(height: 20),
          _field(_name, tr('名称（可选）'), Icons.label_outline_rounded),
          _field(_host, tr('服务器地址'), Icons.dns_rounded, hint: _hostHint),
          _field(
            _port,
            tr('端口'),
            Icons.numbers_rounded,
            hint: _portHint,
            keyboardType: TextInputType.number,
          ),
          _field(_username, tr('用户名'), Icons.person_outline_rounded),
          _field(_password, tr('密码'), Icons.lock_outline_rounded, obscure: true),
          if (_kind == 'smb') ...[
            _field(
              _share,
              tr('共享名（可选）'),
              Icons.share_rounded,
              hint: tr('留空则浏览服务器上的全部共享'),
            ),
            _field(_domain, tr('域（可选）'), Icons.badge_outlined),
          ],
          _field(
            _basePath,
            _kind == 'smb' ? tr('共享内初始目录（可选）') : tr('初始目录（可选）'),
            Icons.folder_open_rounded,
            hint: _kind == 'smb' ? tr('例如 docs（留空为共享根）') : tr('例如 /public'),
          ),
          if (_kind == 'webdav')
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('使用 HTTPS')),
              value: _secure,
              onChanged: (value) => setState(() => _secure = value),
            ),
          if (_kind == 'webdav')
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('信任自签名证书')),
              subtitle: Text(tr('跳过 TLS 证书校验（不安全）')),
              value: _insecureTls,
              onChanged: (value) => setState(() => _insecureTls = value),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(onPressed: _submit, child: Text(tr('保存'))),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    String? hint,
    bool obscure = false,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
