import 'package:flutter/material.dart';

import '../core/breadcrumbs.dart';

/// 可点击的路径面包屑（横向滚动，自动定位到末尾）。
class PathBreadcrumb extends StatefulWidget {
  const PathBreadcrumb({
    super.key,
    required this.path,
    required this.onNavigate,
  });

  final String path;
  final void Function(PathCrumb crumb) onNavigate;

  @override
  State<PathBreadcrumb> createState() => _PathBreadcrumbState();
}

class _PathBreadcrumbState extends State<PathBreadcrumb> {
  final ScrollController _controller = ScrollController(
    initialScrollOffset: 100000,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final crumbs = breadcrumbsFor(widget.path);
    if (crumbs.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      height: 18,
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        itemCount: crumbs.length,
        separatorBuilder: (_, _) =>
            Icon(Icons.chevron_right_rounded, size: 14, color: scheme.outline),
        itemBuilder: (context, index) {
          final crumb = crumbs[index];
          final isLast = index == crumbs.length - 1;
          return GestureDetector(
            onTap: isLast ? null : () => widget.onNavigate(crumb),
            child: Center(
              child: Text(
                crumb.label,
                maxLines: 1,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: isLast ? scheme.onSurface : scheme.primary,
                  fontWeight: isLast ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
