import 'package:flutter/material.dart';

import '../state/drop_controller.dart';

/// 外部文件拖到窗口上方时显示的提示层（放在 `Stack` 中）。
///
/// 使用顶部细横幅 + 极淡的整体着色，避免占用中间区域，为正常浏览操作留出空间。
class DropOverlay extends StatelessWidget {
  const DropOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DropController.instance.dragging,
      builder: (context, dragging, _) {
        if (!dragging) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(
              color: scheme.primary.withValues(alpha: 0.06),
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Material(
                    elevation: 2,
                    borderRadius: BorderRadius.circular(24),
                    color: scheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.download_rounded,
                            size: 20,
                            color: scheme.onPrimaryContainer,
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              '松手导入到「${DropController.instance.activeLabel}」',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: scheme.onPrimaryContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
