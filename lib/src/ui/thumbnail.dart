import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/file_types.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import '../services/platform_service.dart';
import 'entry_visuals.dart';

/// 缩略图缓存与加载（图片走 Rust，视频走系统媒体框架）。
class ThumbnailProvider {
  ThumbnailProvider._();

  static final ThumbnailProvider instance = ThumbnailProvider._();

  final Map<String, Uint8List> _cache = {};
  final Map<String, Future<Uint8List?>> _pending = {};
  static const int _maxEntries = 400;

  Future<Uint8List?> get(String path, int maxPx) {
    final key = '$path|$maxPx';
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    final pending = _pending[key];
    if (pending != null) return pending;

    final future = _load(path, maxPx).then((bytes) {
      _pending.remove(key);
      if (bytes != null) _store(key, bytes);
      return bytes;
    });
    _pending[key] = future;
    return future;
  }

  void _store(String key, Uint8List bytes) {
    if (_cache.length >= _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = bytes;
  }

  Future<Uint8List?> _load(String path, int maxPx) async {
    try {
      final base = path.split('/').last;
      final dot = base.lastIndexOf('.');
      final ext = dot >= 0 ? base.substring(dot + 1) : '';
      if (isVideoExtension(ext)) {
        return await PlatformService.videoThumbnail(path);
      }
      return await OrdoService.instance.thumbnail(path, maxPx);
    } catch (_) {
      return null;
    }
  }
}

/// 列表中的缩略图；加载失败或非图片/视频时回退为类型图标。
class ThumbnailImage extends StatefulWidget {
  const ThumbnailImage({
    super.key,
    required this.entry,
    required this.size,
    this.radius = 12,
  });

  final FileEntry entry;
  final double size;
  final double radius;

  @override
  State<ThumbnailImage> createState() => _ThumbnailImageState();
}

class _ThumbnailImageState extends State<ThumbnailImage> {
  Uint8List? _bytes;
  bool _requested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requested) return;
    _requested = true;
    final maxPx = (widget.size * MediaQuery.of(context).devicePixelRatio)
        .round()
        .clamp(64, 512);
    ThumbnailProvider.instance.get(widget.entry.path, maxPx).then((bytes) {
      if (mounted) setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = colorForEntry(widget.entry, scheme);
    return Container(
      width: widget.size,
      height: widget.size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      child: _bytes != null
          ? Image.memory(
              _bytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => Center(
                child: Icon(iconForEntry(widget.entry), color: accent),
              ),
            )
          : Center(child: Icon(iconForEntry(widget.entry), color: accent)),
    );
  }
}
