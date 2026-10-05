import 'package:flutter/material.dart';

import '../i18n/i18n.dart';

const String ordoRepositoryUrl = 'https://github.com/whynbnb/ordo';

/// 「关于」对话框。
void showOrdoAbout(BuildContext context, String? version) {
  showAboutDialog(
    context: context,
    applicationName: tr('安序 Ordo'),
    applicationVersion: version == null || version.isEmpty ? 'v1.0' : 'v$version',
    applicationIcon: const Icon(Icons.folder_rounded, size: 40),
    applicationLegalese: 'MIT License',
    children: [
      Text(
        tr('一个使用 Flutter + Rust 构建的安卓文件管理器。所有文件操作均由本地 Rust 核心完成。'),
      ),
      const SizedBox(height: 12),
      Text('${tr('基于 MIT 许可证开源')} · ${tr('开源仓库')}'),
      const SizedBox(height: 4),
      SelectableText(
        ordoRepositoryUrl,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ],
  );
}
