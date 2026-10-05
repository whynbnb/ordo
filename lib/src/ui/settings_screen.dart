import 'package:flutter/material.dart';

import '../services/platform_service.dart';
import '../state/prefs_store.dart';

/// 选择应用的结果：`null` 表示取消选择动作本身。
class _PickResult {
  const _PickResult(this.target);
  final OpenWithTarget? target;
}

/// 设置：为各类文件指定「默认跳转查看内容的应用」。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final PrefsStore _prefs = PrefsStore.instance;

  bool get _appLock => _prefs.value('app_lock') == '1';

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_onChanged);
    _prefs.loadIfNeeded();
  }

  @override
  void dispose() {
    _prefs.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _pick(OpenWithCategory category) async {
    final apps = await PlatformService.resolveActivities(category.mime);
    if (!mounted) return;
    final result = await showModalBottomSheet<_PickResult>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(
                  '默认打开方式 · ${category.label}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.help_outline_rounded),
                title: const Text('每次询问'),
                subtitle: const Text('不设置默认应用，弹出系统选择器'),
                trailing: _prefs.targetForCategory(category.key) == null
                    ? Icon(Icons.check_rounded, color: scheme.primary)
                    : null,
                onTap: () => Navigator.pop(sheetContext, const _PickResult(null)),
              ),
              if (apps.isEmpty)
                const ListTile(
                  enabled: false,
                  leading: Icon(Icons.apps_outlined),
                  title: Text('未找到可处理该类型的应用'),
                )
              else
                for (final app in apps)
                  ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        _initial(app['label']?.toString() ?? '?'),
                      ),
                    ),
                    title: Text(app['label']?.toString() ?? ''),
                    subtitle: Text(app['package']?.toString() ?? ''),
                    trailing: _isCurrent(category.key, app)
                        ? Icon(Icons.check_rounded, color: scheme.primary)
                        : null,
                    onTap: () => Navigator.pop(
                      sheetContext,
                      _PickResult(
                        OpenWithTarget(
                          package: app['package']?.toString() ?? '',
                          activity: app['activity']?.toString() ?? '',
                          label: app['label']?.toString() ?? '',
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        );
      },
    );
    if (result == null || !mounted) return;
    await _prefs.setTarget(category.key, result.target);
    _snack(
      result.target == null ? '已设为每次询问' : '默认打开方式：${result.target!.label}',
    );
  }

  bool _isCurrent(String category, Map<String, dynamic> app) {
    final current = _prefs.targetForCategory(category);
    return current != null && current.package == app['package'];
  }

  String _initial(String label) {
    final trimmed = label.trim();
    return trimmed.isEmpty ? '?' : trimmed[0];
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleLock(bool value) async {
    if (value) {
      final available = await PlatformService.lockAvailable();
      if (!available) {
        _snack('请先在系统设置中设置锁屏密码 / 图案');
        return;
      }
      await _prefs.setValue('app_lock', '1');
      _snack('已开启应用锁');
    } else {
      final ok = await PlatformService.authenticate();
      if (!ok) return;
      await _prefs.setValue('app_lock', null);
      _snack('已关闭应用锁');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const SizedBox(height: 8),
          Text(
            '安全与隐私',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('应用锁'),
            subtitle: const Text('启动或回到前台时验证设备锁屏凭证'),
            value: _appLock,
            onChanged: _toggleLock,
          ),
          const Divider(),
          const SizedBox(height: 8),
          Text(
            '默认打开方式',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '为「用其它应用打开」指定默认应用；未指定时每次弹出系统选择器。'
            '图片 / 音频 / 文本仍可在应用内直接预览。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          for (final category in openWithCategories) ...[
            _categoryTile(category),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _categoryTile(OpenWithCategory category) {
    final target = _prefs.targetForCategory(category.key);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(_iconFor(category.key), color: scheme.primary),
        title: Text(category.label),
        subtitle: Text(target?.label ?? '每次询问'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _pick(category),
      ),
    );
  }

  IconData _iconFor(String category) => switch (category) {
    'image' => Icons.image_rounded,
    'audio' => Icons.music_note_rounded,
    'video' => Icons.movie_rounded,
    'text' => Icons.article_rounded,
    'pdf' => Icons.picture_as_pdf_rounded,
    'apk' => Icons.android_rounded,
    _ => Icons.insert_drive_file_rounded,
  };
}
