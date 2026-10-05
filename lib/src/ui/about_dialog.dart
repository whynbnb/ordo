import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../services/platform_service.dart';

const String ordoRepositoryUrl = 'https://github.com/whynbnb/ordo';

/// 「关于」对话框。
void showOrdoAbout(BuildContext context, String? version) {
  final scheme = Theme.of(context).colorScheme;
  showAboutDialog(
    context: context,
    applicationName: tr('安序 Ordo'),
    applicationVersion: version == null || version.isEmpty ? 'v1.0' : 'v$version',
    applicationIcon: ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.asset(
        'assets/icon/app_icon.png',
        width: 44,
        height: 44,
      ),
    ),
    applicationLegalese: 'MIT License',
    children: [
      Text(
        tr('一个使用 Flutter + Rust 构建的安卓文件管理器。所有文件操作均由本地 Rust 核心完成。'),
      ),
      const SizedBox(height: 12),
      Text(tr('基于 MIT 许可证开源')),
      const SizedBox(height: 4),
      InkWell(
        onTap: () => PlatformService.openUrl(ordoRepositoryUrl),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  ordoRepositoryUrl,
                  style: TextStyle(
                    color: scheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.open_in_new_rounded, size: 15, color: scheme.primary),
            ],
          ),
        ),
      ),
    ],
  );
}
