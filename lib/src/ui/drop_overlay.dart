import 'package:flutter/material.dart';

import '../state/drop_controller.dart';

/// 外部文件拖到窗口上方时显示的提示层（放在 `Stack` 中）。
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
            child: Container(
              color: scheme.primary.withValues(alpha: 0.10),
              alignment: Alignment.center,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: scheme.primary, width: 2),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download_rounded,
                      size: 44,
                      color: scheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '松手导入到「${DropController.instance.activeLabel}」',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
