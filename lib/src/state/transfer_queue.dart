import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/ordo_service.dart';
import '../services/platform_service.dart';

enum TransferState { queued, running, done, failed, cancelled }

/// 一个后台传输任务。
class TransferTask {
  TransferTask({
    required this.id,
    required this.sources,
    required this.dest,
    required this.isMove,
  });

  final int id;
  List<String> sources;
  final String dest;
  final bool isMove;

  TransferState state = TransferState.queued;
  int jobId = 0;
  int done = 0;
  int total = 0;
  String? error;

  String get label => isMove ? '移动' : '复制';
  double? get fraction => total > 0 ? (done / total).clamp(0.0, 1.0) : null;
}

/// 后台传输队列：串行执行复制 / 移动，离开页面后继续运行。
///
/// 任务失败或取消后保留在列表里，可重试（只重跑未完成的源）。
class TransferQueue extends ChangeNotifier {
  TransferQueue._();

  static final TransferQueue instance = TransferQueue._();

  final List<TransferTask> _tasks = <TransferTask>[];
  bool _running = false;
  int _nextId = 1;

  /// 每次有任务完成时自增，供界面刷新目标目录。
  final ValueNotifier<int> completed = ValueNotifier<int>(0);

  List<TransferTask> get tasks => List.unmodifiable(_tasks);

  int get activeCount =>
      _tasks.where((t) => t.state != TransferState.done).length;

  int enqueue(List<String> sources, String dest, {required bool isMove}) {
    final task = TransferTask(
      id: _nextId++,
      sources: List.of(sources),
      dest: dest,
      isMove: isMove,
    );
    _tasks.insert(0, task);
    notifyListeners();
    _pump();
    return task.id;
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        TransferTask? next;
        for (final task in _tasks) {
          if (task.state == TransferState.queued) {
            next = task;
            break;
          }
        }
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _running = false;
      notifyListeners();
      PlatformService.transferDone();
    }
  }

  Future<void> _run(TransferTask task) async {
    final service = OrdoService.instance;
    task.state = TransferState.running;
    task.error = null;
    task.jobId = service.jobCreate();
    notifyListeners();
    PlatformService.transferNotify(
      '正在${task.label}',
      '${task.sources.length} 项 → ${task.dest}',
      -1,
    );

    Timer? timer;
    timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      try {
        final progress = service.jobStatus(task.jobId);
        task.done = progress.progress;
        task.total = progress.total;
        if (task.state == TransferState.running) {
          notifyListeners();
          PlatformService.transferNotify(
            '正在${task.label}',
            task.dest,
            task.total > 0 ? (task.done * 100 ~/ task.total) : -1,
          );
        }
      } catch (_) {
        // 忽略轮询异常。
      }
    });

    try {
      final result = task.isMove
          ? await service.move(task.sources, task.dest, jobId: task.jobId)
          : await service.copy(task.sources, task.dest, jobId: task.jobId);
      if (task.state == TransferState.cancelled) {
        return;
      }
      task.state = TransferState.done;
      task.done = task.total > 0 ? task.total : task.done;
      if (result.errors.isNotEmpty) {
        task.error = result.errors.first;
      }
      completed.value++;
    } catch (error) {
      if (task.state != TransferState.cancelled) {
        task.state = TransferState.failed;
        task.error = '$error';
      }
    } finally {
      timer.cancel();
      service.jobCleanup(task.jobId);
      notifyListeners();
    }
  }

  void cancel(TransferTask task) {
    if (task.state == TransferState.running) {
      OrdoService.instance.jobCancel(task.jobId);
    }
    if (task.state == TransferState.queued ||
        task.state == TransferState.running) {
      task.state = TransferState.cancelled;
      notifyListeners();
    }
  }

  /// 重试：先跳过目标目录中已存在的同名项（文件级续传），再重新排队。
  void retry(TransferTask task) {
    if (task.state == TransferState.done) return;
    _retry(task);
  }

  Future<void> _retry(TransferTask task) async {
    try {
      final entries = await OrdoService.instance.listDir(task.dest);
      final names = entries.map((entry) => entry.name).toSet();
      task.sources = task.sources.where((source) {
        final base = source.replaceAll(RegExp(r'/+$'), '').split('/').last;
        return !names.contains(base);
      }).toList();
    } catch (_) {
      // 无法列目录时按原样重试。
    }
    if (task.sources.isEmpty) {
      task.state = TransferState.done;
      task.error = null;
      notifyListeners();
      return;
    }
    task.state = TransferState.queued;
    task.error = null;
    notifyListeners();
    _pump();
  }

  void remove(TransferTask task) {
    _tasks.remove(task);
    notifyListeners();
  }

  void clearFinished() {
    _tasks.removeWhere(
      (t) =>
          t.state == TransferState.done ||
          t.state == TransferState.cancelled ||
          t.state == TransferState.failed,
    );
    notifyListeners();
  }
}
