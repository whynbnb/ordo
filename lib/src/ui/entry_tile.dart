import 'package:flutter/material.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/models.dart';
import 'entry_visuals.dart';
import 'thumbnail.dart';
import '../i18n/i18n.dart';

class EntryTile extends StatelessWidget {
  const EntryTile({
    super.key,
    required this.entry,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    this.onMenu,
    this.labelColor,
  });

  final FileEntry entry;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onMenu;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = colorForEntry(entry, scheme);
    final subtitle = entry.isDir
        ? formatDate(entry.modified)
        : '${formatBytes(entry.size)} · ${formatDate(entry.modified)}';

    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              if (selectionMode)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected ? scheme.primary : scheme.outline,
                  ),
                ),
              if (isImageExtension(entry.extension) ||
                  isVideoExtension(entry.extension))
                ThumbnailImage(entry: entry, size: 44)
              else
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(iconForEntry(entry), color: accent),
                ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (!selectionMode && onMenu != null)
                IconButton(
                  icon: const Icon(Icons.more_vert_rounded),
                  tooltip: tr('更多'),
                  onPressed: onMenu,
                ),
              if (labelColor != null)
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(left: 4),
                  decoration: BoxDecoration(
                    color: labelColor,
                    shape: BoxShape.circle,
                  ),
                ),
              if (entry.isSymlink && !selectionMode)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(
                    Icons.link_rounded,
                    size: 16,
                    color: scheme.outline,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 网格视图中的单个文件 / 文件夹。
class GridEntryTile extends StatelessWidget {
  const GridEntryTile({
    super.key,
    required this.entry,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    this.onMenu,
    this.labelColor,
    this.iconExtent = 52,
  });

  final FileEntry entry;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onMenu;
  final Color? labelColor;
  final double iconExtent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = colorForEntry(entry, scheme);
    final isMedia =
        isImageExtension(entry.extension) || isVideoExtension(entry.extension);

    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onMenu,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Center(
                      child: isMedia
                          ? ThumbnailImage(
                              entry: entry,
                              size: iconExtent,
                              radius: 12,
                            )
                          : Container(
                              width: iconExtent,
                              height: iconExtent,
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                iconForEntry(entry),
                                color: accent,
                                size: iconExtent * 0.6,
                              ),
                            ),
                    ),
                    if (selectionMode)
                      Positioned(
                        top: 0,
                        left: 0,
                        child: Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 20,
                          color: selected ? scheme.primary : scheme.outline,
                        ),
                      ),
                    if (labelColor != null)
                      Positioned(
                        top: 2,
                        right: 2,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: labelColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                entry.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
