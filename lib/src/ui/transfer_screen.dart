import 'package:flutter/material.dart';

import '../core/format.dart';
import '../state/transfer_queue.dart';
import '../i18n/i18n.dart';

/// 后台传输队列界面。
class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key});

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  final TransferQueue _queue = TransferQueue.instance;

  @override
  void initState() {
    super.initState();
    _queue.addListener(_onChanged);
  }

  @override
  void dispose() {
    _queue.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _queue.tasks;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('传输')),
        actions: [
          if (tasks.isNotEmpty)
            IconButton(
              tooltip: tr('清除已完成'),
              icon: const Icon(Icons.cleaning_services_outlined),
              onPressed: _queue.clearFinished,
            ),
        ],
      ),
      body: tasks.isEmpty
          ? Center(
              child: Text(
                tr('没有传输任务'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : ListView.separated(
              itemCount: tasks.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) => _taskTile(context, tasks[index]),
            ),
    );
  }

  Widget _taskTile(BuildContext context, TransferTask task) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        task.isMove ? Icons.drive_file_move_rounded : Icons.copy_rounded,
        color: scheme.primary,
      ),
      title: Text(tr('{p0} {p1} 项', {'p0': task.label, 'p1': task.sources.length})),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.dest,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          if (task.state == TransferState.running)
            LinearProgressIndicator(value: task.fraction),
          const SizedBox(height: 2),
          Text(_statusText(task)),
          if (task.error != null)
            Text(
              task.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.error),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (task.state == TransferState.running ||
              task.state == TransferState.queued)
            IconButton(
              tooltip: tr('取消'),
              icon: const Icon(Icons.close_rounded),
              onPressed: () => _queue.cancel(task),
            ),
          if (task.state == TransferState.failed ||
              task.state == TransferState.cancelled)
            IconButton(
              tooltip: tr('重试'),
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => _queue.retry(task),
            ),
          if (task.state == TransferState.done)
            IconButton(
              tooltip: tr('移除'),
              icon: const Icon(Icons.check_rounded, color: Colors.green),
              onPressed: () => _queue.remove(task),
            ),
        ],
      ),
    );
  }

  String _statusText(TransferTask task) {
    switch (task.state) {
      case TransferState.queued:
        return tr('排队中');
      case TransferState.running:
        final amount = task.total > 0
            ? '${formatBytes(task.done)} / ${formatBytes(task.total)}'
            : tr('处理中…');
        final fraction = task.fraction;
        return fraction == null
            ? amount
            : '${(fraction * 100).toStringAsFixed(0)}% · $amount';
      case TransferState.done:
        return tr('已完成');
      case TransferState.failed:
        return tr('失败');
      case TransferState.cancelled:
        return tr('已取消');
    }
  }
}
