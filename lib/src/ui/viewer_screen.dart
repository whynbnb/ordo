import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import '../services/platform_service.dart';
import 'dialogs.dart';
import 'open_entry.dart';
import '../i18n/i18n.dart';

/// 应用内预览：图片渲染、音频播放、文本查看与编辑。
///
/// 文件读取 / 写入全部经由 Rust 核心；音频通过与系统 `MediaPlayer` 通信播放，
/// 视频不做应用内预览。
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.entry});

  final FileEntry entry;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

enum _PreviewKind { image, audio, text, pdf }

class _ViewerScreenState extends State<ViewerScreen> {
  final OrdoService _service = OrdoService.instance;

  bool _loading = true;
  String? _error;

  Uint8List? _imageBytes;
  TextContent? _text;
  final TextEditingController _controller = TextEditingController();
  bool _editMode = false;
  bool _saving = false;

  int _durationMs = 0;
  int _positionMs = 0;
  bool _playing = false;
  bool _audioReady = false;
  Timer? _audioTimer;

  // PDF
  String? _pdfPath;
  int _pdfPageCount = 0;
  int _pdfPageIndex = 0;
  final Map<int, Future<Uint8List?>> _pdfFutures = {};

  _PreviewKind get _kind {
    final ext = widget.entry.extension;
    if (isImageExtension(ext)) return _PreviewKind.image;
    if (isAudioExtension(ext)) return _PreviewKind.audio;
    if (isPdfExtension(ext)) return _PreviewKind.pdf;
    return _PreviewKind.text;
  }

  bool get _canEdit =>
      _kind == _PreviewKind.text &&
      _text != null &&
      !(_text!.truncated) &&
      _error == null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _audioTimer?.cancel();
    _controller.dispose();
    PlatformService.audioStop();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      switch (_kind) {
        case _PreviewKind.image:
          const maxPreview = 32 * 1024 * 1024;
          if (widget.entry.size > maxPreview) {
            setState(() {
              _error = tr('图片过大（{p0}），无法在应用内预览', {'p0': formatBytes(widget.entry.size)});
              _loading = false;
            });
            return;
          }
          final bytes = await _service.readBytes(widget.entry.path);
          if (!mounted) return;
          setState(() {
            _imageBytes = bytes;
            _loading = false;
          });
        case _PreviewKind.text:
          final text = await _service.readText(widget.entry.path);
          if (!mounted) return;
          setState(() {
            _text = text;
            _controller.text = text.content;
            _loading = false;
          });
        case _PreviewKind.audio:
          await _loadAudio();
        case _PreviewKind.pdf:
          await _loadPdf();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _loadPdf() async {
    var path = widget.entry.path;
    if (isRemotePath(path)) {
      final cached = await _service.downloadToCache(path);
      path = cached.path;
    }
    final count = await PlatformService.pdfPageCount(path);
    if (!mounted) return;
    if (count <= 0) {
      setState(() {
        _error = tr('无法打开此 PDF（可能已加密或损坏）');
        _loading = false;
      });
      return;
    }
    setState(() {
      _pdfPath = path;
      _pdfPageCount = count;
      _pdfPageIndex = 0;
      _loading = false;
    });
  }

  Future<Uint8List?> _renderPdfPage(int index) async {
    final path = _pdfPath;
    if (path == null) return null;
    return PlatformService.pdfPage(path, index);
  }

  Future<void> _loadAudio() async {
    var path = widget.entry.path;
    if (isRemotePath(path)) {
      final cached = await _service.downloadToCache(path);
      path = cached.path;
    }
    final duration = await PlatformService.audioLoad(path);
    if (!mounted) return;
    if (duration < 0) {
      setState(() {
        _error = tr('无法播放此音频文件');
        _loading = false;
      });
      return;
    }
    setState(() {
      _durationMs = duration;
      _audioReady = true;
      _loading = false;
    });
    _audioTimer?.cancel();
    _audioTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final status = await PlatformService.audioStatus();
      if (!mounted) return;
      setState(() {
        _positionMs = status.position;
        if (status.duration > 0) _durationMs = status.duration;
        _playing = status.playing;
      });
    });
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await PlatformService.audioPause();
    } else {
      await PlatformService.audioPlay();
    }
    if (!mounted) return;
    setState(() => _playing = !_playing);
  }

  void _enterEdit() {
    if (!_canEdit) {
      _snack(tr('文件过大，未完整加载，无法编辑'));
      return;
    }
    _controller.text = _text!.content;
    setState(() => _editMode = true);
  }

  void _cancelEdit() {
    _controller.text = _text?.content ?? '';
    setState(() => _editMode = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final entry = await _service.writeText(
        widget.entry.path,
        _controller.text,
      );
      if (!mounted) return;
      setState(() {
        _text = TextContent(
          content: _controller.text,
          truncated: false,
          size: entry.size,
        );
        _editMode = false;
        _saving = false;
      });
      _snack(tr('已保存'));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(tr('保存失败：{error}', {'error': error}));
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: _buildActions(context),
      ),
      body: _buildBody(context),
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    if (_editMode) {
      return [
        IconButton(
          tooltip: tr('取消'),
          icon: const Icon(Icons.close_rounded),
          onPressed: _saving ? null : _cancelEdit,
        ),
        IconButton(
          tooltip: tr('保存'),
          icon: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded),
          onPressed: _saving ? null : _save,
        ),
      ];
    }
    return [
      if (_kind == _PreviewKind.text)
        IconButton(
          tooltip: tr('编辑'),
          icon: const Icon(Icons.edit_outlined),
          onPressed: _canEdit ? _enterEdit : null,
        ),
      if (_kind == _PreviewKind.image)
        PopupMenuButton<String>(
          tooltip: tr('图片操作'),
          icon: const Icon(Icons.photo_filter_rounded),
          onSelected: _onImageAction,
          itemBuilder: (_) => [
            PopupMenuItem(value: 'rotate_left', child: Text(tr('向左旋转'))),
            PopupMenuItem(value: 'rotate_right', child: Text(tr('向右旋转'))),
            PopupMenuItem(value: 'rotate_180', child: Text(tr('旋转 180°'))),
            PopupMenuDivider(),
            PopupMenuItem(value: 'save_as', child: Text(tr('另存为'))),
            PopupMenuItem(value: 'wallpaper', child: Text(tr('设为壁纸'))),
          ],
        ),
      IconButton(
        tooltip: tr('用其它应用打开'),
        icon: const Icon(Icons.open_in_new_rounded),
        onPressed: _loading
            ? null
            : () => openWithDefault(context, widget.entry),
      ),
    ];
  }

  Future<void> _onImageAction(String value) async {
    switch (value) {
      case 'rotate_left':
        await _rotate('left');
      case 'rotate_right':
        await _rotate('right');
      case 'rotate_180':
        await _rotate('180');
      case 'save_as':
        await _saveAs();
      case 'wallpaper':
        await _setWallpaper();
    }
  }

  Future<void> _rotate(String direction) async {
    try {
      await _service.rotateImage(widget.entry.path, direction);
      _imageBytes = null;
      await _load();
      _snack(tr('已旋转'));
    } catch (error) {
      _snack(tr('旋转失败：{error}', {'error': error}));
    }
  }

  Future<void> _saveAs() async {
    final dot = widget.entry.name.lastIndexOf('.');
    final base = dot > 0
        ? widget.entry.name.substring(0, dot)
        : widget.entry.name;
    final extension = dot > 0 ? widget.entry.name.substring(dot) : '';
    final name = await showNameDialog(
      context,
      title: tr('另存为'),
      initialText: '${base}_copy$extension',
      confirmLabel: tr('保存'),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final dest = joinPath(parentOf(widget.entry.path), name);
    try {
      await _service.copyFile(widget.entry.path, dest);
      _snack(tr('已保存为「{name}」', {'name': name}));
    } catch (error) {
      _snack(tr('保存失败：{error}', {'error': error}));
    }
  }

  Future<void> _setWallpaper() async {
    try {
      var path = widget.entry.path;
      if (isRemotePath(path)) {
        final cached = await _service.downloadToCache(path);
        path = cached.path;
      }
      final ok = await PlatformService.setWallpaper(path);
      _snack(ok ? tr('已设为壁纸') : tr('设置壁纸失败'));
    } catch (error) {
      _snack(tr('设置壁纸失败：{error}', {'error': error}));
    }
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 48),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: _load, child: Text(tr('重试'))),
            ],
          ),
        ),
      );
    }

    switch (_kind) {
      case _PreviewKind.image:
        return _buildImage();
      case _PreviewKind.audio:
        return _buildAudio(context);
      case _PreviewKind.pdf:
        return _buildPdf(context);
      case _PreviewKind.text:
        return _buildText(context);
    }
  }

  Widget _buildPdf(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            itemCount: _pdfPageCount,
            onPageChanged: (index) => setState(() => _pdfPageIndex = index),
            itemBuilder: (context, index) {
              final future = _pdfFutures.putIfAbsent(
                index,
                () => _renderPdfPage(index),
              );
              return FutureBuilder<Uint8List?>(
                future: future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final bytes = snapshot.data;
                  if (bytes == null) {
                    return Center(
                      child: Text(
                        tr('无法渲染第 {p0} 页', {'p0': index + 1}),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return InteractiveViewer(
                    maxScale: 6,
                    child: Center(
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            tr('第 {p0} / {_pdfPageCount} 页 · 左右滑动翻页', {'p0': _pdfPageIndex + 1, '_pdfPageCount': _pdfPageCount}),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImage() {
    final bytes = _imageBytes;
    if (bytes == null) return const SizedBox.shrink();
    return Container(
      color: const Color(0xFF121212),
      width: double.infinity,
      child: InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => Text(
              tr('无法预览此图片'),
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAudio(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!_audioReady) return const SizedBox.shrink();
    final duration = _durationMs > 0 ? _durationMs : 0;
    final position = _positionMs.clamp(0, duration == 0 ? 0 : duration);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_note_rounded, size: 72, color: scheme.primary),
            const SizedBox(height: 20),
            Text(
              widget.entry.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              tr('音频 · {p0}', {'p0': mimeOfExtension(widget.entry.extension)}),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            Slider(
              value: position.toDouble(),
              max: duration > 0 ? duration.toDouble() : 1,
              onChanged: duration > 0
                  ? (value) => setState(() => _positionMs = value.toInt())
                  : null,
              onChangeEnd: (value) => PlatformService.audioSeek(value.toInt()),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatDuration(position)),
                Text(_formatDuration(duration)),
              ],
            ),
            const SizedBox(height: 8),
            IconButton.filled(
              iconSize: 40,
              onPressed: _audioReady ? _togglePlay : null,
              icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildText(BuildContext context) {
    final text = _text;
    if (text == null) return const SizedBox.shrink();
    if (_editMode) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _controller,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            height: 1.5,
          ),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );
    }
    return Column(
      children: [
        if (text.truncated)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(tr('文件较大，仅显示前面部分（共 {p0}）', {'p0': formatBytes(text.size)})),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              text.content.isEmpty ? tr('（空文件）') : text.content,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatDuration(int ms) {
    final totalSeconds = (ms / 1000).floor().clamp(0, 359999);
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
