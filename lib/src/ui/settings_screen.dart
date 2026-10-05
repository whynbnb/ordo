import 'package:flutter/material.dart';

import '../services/platform_service.dart';
import '../i18n/locale_store.dart';
import '../state/prefs_store.dart';
import '../state/theme_store.dart';
import 'about_dialog.dart';
import 'crash_log_screen.dart';
import 'home_layout_screen.dart';
import '../i18n/i18n.dart';

/// 选择应用的结果：`null` 表示取消选择动作本身。
class _PickResult {
  const _PickResult(this.target);
  final OpenWithTarget? target;
}

/// 设置：外观 / 语言 / 安全 / 默认打开方式 / 关于。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.version});

  final String? version;

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
                  tr('默认打开方式 · {p0}', {'p0': tr(category.label)}),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.help_outline_rounded),
                title: Text(tr('每次询问')),
                subtitle: Text(tr('不设置默认应用，弹出系统选择器')),
                trailing: _prefs.targetForCategory(category.key) == null
                    ? Icon(Icons.check_rounded, color: scheme.primary)
                    : null,
                onTap: () => Navigator.pop(sheetContext, const _PickResult(null)),
              ),
              if (apps.isEmpty)
                ListTile(
                  enabled: false,
                  leading: Icon(Icons.apps_outlined),
                  title: Text(tr('未找到可处理该类型的应用')),
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
      result.target == null ? tr('已设为每次询问') : tr('默认打开方式：{p0}', {'p0': result.target!.label}),
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
        _snack(tr('请先在系统设置中设置锁屏密码 / 图案'));
        return;
      }
      await _prefs.setValue('app_lock', '1');
      _snack(tr('已开启应用锁'));
    } else {
      final ok = await PlatformService.authenticate();
      if (!ok) return;
      await _prefs.setValue('app_lock', null);
      _snack(tr('已关闭应用锁'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('设置'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const SizedBox(height: 8),
          Text(
            tr('外观'),
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final mode in OrdoThemeMode.values)
                ChoiceChip(
                  label: Text(_modeLabel(mode)),
                  selected: ThemeStore.instance.mode == mode,
                  onSelected: (_) => ThemeStore.instance.setMode(mode),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            tr('主色'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final color in ordoSeedColors)
                InkWell(
                  onTap: () => ThemeStore.instance.setSeed(color),
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: ThemeStore.instance.seed.toARGB32() ==
                              color.toARGB32()
                          ? Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 3,
                            )
                          : null,
                    ),
                    child: ThemeStore.instance.seed.toARGB32() ==
                            color.toARGB32()
                        ? const Icon(Icons.check_rounded, color: Colors.white)
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            tr('语言'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: Text(tr('跟随系统')),
                selected: LocaleStore.instance.mode == 'system',
                onSelected: (_) => LocaleStore.instance.setMode('system'),
              ),
              ChoiceChip(
                label: Text(tr('简体中文')),
                selected: LocaleStore.instance.mode == 'zh',
                onSelected: (_) => LocaleStore.instance.setMode('zh'),
              ),
              ChoiceChip(
                label: const Text('English'),
                selected: LocaleStore.instance.mode == 'en',
                onSelected: (_) => LocaleStore.instance.setMode('en'),
              ),
            ],
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dashboard_customize_outlined),
            title: Text(tr('首页布局')),
            subtitle: Text(tr('调整工具与常用目录的顺序 / 显隐')),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const HomeLayoutScreen(),
                ),
              );
            },
          ),
          const Divider(height: 32),
          Text(
            tr('安全与隐私'),
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('应用锁')),
            subtitle: Text(tr('启动或回到前台时验证设备锁屏凭证')),
            value: _appLock,
            onChanged: _toggleLock,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bug_report_outlined),
            title: Text(tr('崩溃日志')),
            subtitle: Text(tr('查看、导出或清空错误日志')),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const CrashLogScreen(),
                ),
              );
            },
          ),
          const Divider(),
          const SizedBox(height: 8),
          Text(
            tr('默认打开方式'),
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            tr('为「用其它应用打开」指定默认应用；未指定时每次弹出系统选择器。图片 / 音频 / 文本仍可在应用内直接预览。'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          for (final category in openWithCategories) ...[
            _categoryTile(category),
            const SizedBox(height: 8),
          ],
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline_rounded),
            title: Text(tr('关于')),
            subtitle: Text(
              widget.version == null || widget.version!.isEmpty
                  ? 'v1.0'
                  : 'v${widget.version}',
            ),
            onTap: () => showOrdoAbout(context, widget.version),
          ),
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
        title: Text(tr(category.label)),
        subtitle: Text(target?.label ?? tr('每次询问')),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _pick(category),
      ),
    );
  }

  String _modeLabel(OrdoThemeMode mode) => switch (mode) {
    OrdoThemeMode.system => tr('跟随系统'),
    OrdoThemeMode.light => tr('浅色'),
    OrdoThemeMode.dark => tr('深色'),
    OrdoThemeMode.black => tr('纯黑'),
  };

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
