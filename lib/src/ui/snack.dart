import 'dart:async';

import 'package:flutter/material.dart';

OverlayEntry? _current;
Timer? _timer;

/// 轻量、非阻塞的提示。
///
/// 与 [SnackBar] 不同，它铺在 [Overlay] 上并用 [IgnorePointer] 包裹，
/// **不会拦截任何点击**，因此不会挡住底部栏 / 悬浮按钮；默认约 1.5s 自动消失。
void showOrdoSnack(
  BuildContext context,
  String message, {
  bool error = false,
  Duration duration = const Duration(milliseconds: 1500),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;

  _timer?.cancel();
  _current?.remove();
  _current = null;

  final entry = OverlayEntry(
    builder: (overlayContext) {
      return Positioned(
        left: 16,
        right: 16,
        bottom: 96,
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: (error ? scheme.errorContainer : scheme.inverseSurface)
                    .withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(blurRadius: 10, color: Color(0x33000000)),
                ],
              ),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: error ? scheme.onErrorContainer : scheme.onInverseSurface,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  overlay.insert(entry);
  _current = entry;
  _timer = Timer(duration, () {
    entry.remove();
    if (identical(_current, entry)) _current = null;
  });
}
