import 'dart:async';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import '../i18n/i18n.dart';

/// 运行一个带进度与取消的长任务，期间显示进度对话框。
Future<T> runWithJobProgress<T>(
  BuildContext context,
  String title,
  Future<T> Function(int jobId) run,
) async {
  final service = OrdoService.instance;
  final jobId = service.jobCreate();
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _JobProgressDialog(title: title, jobId: jobId),
  ).ignore();
  try {
    return await run(jobId);
  } finally {
    if (navigator.canPop()) navigator.pop();
    service.jobCleanup(jobId);
  }
}

class _JobProgressDialog extends StatefulWidget {
  const _JobProgressDialog({required this.title, required this.jobId});

  final String title;
  final int jobId;

  @override
  State<_JobProgressDialog> createState() => _JobProgressDialogState();
}

class _JobProgressDialogState extends State<_JobProgressDialog> {
  final OrdoService _service = OrdoService.instance;

  JobProgress _progress = JobProgress.idle;
  bool _cancelling = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      try {
        final value = _service.jobStatus(widget.jobId);
        if (mounted) setState(() => _progress = value);
      } catch (_) {
        // 忽略轮询异常。
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fraction = _progress.fraction;
    final amount = _progress.total > 0
        ? '${formatBytes(_progress.progress)} / ${formatBytes(_progress.total)}'
        : tr('处理中…');
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: fraction),
            const SizedBox(height: 12),
            Text(
              fraction == null
                  ? amount
                  : '${(fraction * 100).toStringAsFixed(0)}% · $amount',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _cancelling
                ? null
                : () {
                    setState(() => _cancelling = true);
                    _service.jobCancel(widget.jobId);
                  },
            child: Text(_cancelling ? tr('正在取消…') : tr('取消')),
          ),
        ],
      ),
    );
  }
}
