import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import '../services/platform_service.dart';

/// 应用内预览：文本直接显示，图片以字节渲染（读取全部经由 Rust 核心）。
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.entry});

  final FileEntry entry;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  final OrdoService _service = OrdoService.instance;

  bool _loading = true;
  String? _error;
  TextContent? _text;
  Uint8List? _imageBytes;

  bool get _isImage => isImageExtension(widget.entry.extension);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_isImage) {
        const maxPreview = 32 * 1024 * 1024;
        if (widget.entry.size > maxPreview) {
          setState(() {
            _error = '图片过大（${formatBytes(widget.entry.size)}），无法在应用内预览';
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
      } else {
        final text = await _service.readText(widget.entry.path);
        if (!mounted) return;
        setState(() {
          _text = text;
          _loading = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
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
        actions: [
          IconButton(
            tooltip: '用其它应用打开',
            icon: const Icon(Icons.open_in_new_rounded),
            onPressed: () => PlatformService.openFile(
              widget.entry.path,
              mime: mimeOfExtension(widget.entry.extension),
            ),
          ),
        ],
      ),
      body: _buildBody(context),
    );
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
              FilledButton.tonal(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_isImage && _imageBytes != null) {
      return Container(
        color: const Color(0xFF121212),
        width: double.infinity,
        child: InteractiveViewer(
          maxScale: 6,
          child: Center(
            child: Image.memory(
              _imageBytes!,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => const Text(
                '无法预览此图片',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ),
        ),
      );
    }

    final text = _text;
    if (text == null) {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        if (text.truncated)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('文件较大，仅显示前面部分（共 ${formatBytes(text.size)}）'),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              text.content.isEmpty ? '（空文件）' : text.content,
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
}
