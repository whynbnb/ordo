import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ordo_service.dart';

/// 显示二维码（内容由 Rust 生成的 PNG 渲染）。
Future<void> showQrDialog(
  BuildContext context, {
  required String title,
  required String data,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _QrDialog(title: title, data: data),
  );
}

class _QrDialog extends StatefulWidget {
  const _QrDialog({required this.title, required this.data});

  final String title;
  final String data;

  @override
  State<_QrDialog> createState() => _QrDialogState();
}

class _QrDialogState extends State<_QrDialog> {
  bool _loading = true;
  String? _error;
  Uint8List? _bytes;

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
      final bytes = await OrdoService.instance.qrPng(widget.data, scale: 8);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.data));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已复制')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: _loading
          ? const SizedBox(
              height: 200,
              child: Center(child: CircularProgressIndicator()),
            )
          : _error != null
          ? Text(_error!)
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_bytes != null)
                  Image.memory(_bytes!, width: 240, height: 240)
                else
                  const Text('无法生成二维码'),
                const SizedBox(height: 12),
                SelectableText(
                  widget.data,
                  maxLines: 3,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
      actions: [
        TextButton(onPressed: _copy, child: const Text('复制内容')),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
