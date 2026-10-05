import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../services/ordo_service.dart';
import '../i18n/i18n.dart';

/// 存储趋势：记录并比较目录用量快照。
class TrendScreen extends StatefulWidget {
  const TrendScreen({super.key, required this.root, required this.title});

  final String root;
  final String title;

  @override
  State<TrendScreen> createState() => _TrendScreenState();
}

class _TrendScreenState extends State<TrendScreen> {
  final OrdoService _service = OrdoService.instance;

  List<TrendSnapshot> _history = const [];
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final history = await _service.trendHistory(widget.root);
      if (!mounted) return;
      setState(() {
        _history = history;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  Future<void> _record() async {
    setState(() => _busy = true);
    try {
      final history = await _service.trendRecord(widget.root);
      if (!mounted) return;
      setState(() {
        _history = history;
        _busy = false;
      });
      _snack(tr('已记录当前快照'));
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(tr('记录失败：{error}', {'error': error}));
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
        title: Text(tr('存储趋势「{p0}」', {'p0': widget.title})),
        actions: [
          IconButton(
            tooltip: tr('记录当前快照'),
            onPressed: _busy ? null : _record,
            icon: const Icon(Icons.add_chart_rounded),
          ),
        ],
      ),
      body: _busy && _history.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : _history.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.show_chart_rounded,
                    size: 56,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 12),
                  Text(tr('还没有快照记录')),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _record,
                    icon: const Icon(Icons.add_chart_rounded),
                    label: Text(tr('记录当前快照')),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _summary(context),
                const SizedBox(height: 16),
                _chart(context),
                const SizedBox(height: 16),
                Text(
                  tr('历史记录'),
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                for (final snapshot in _history.reversed)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.circle, size: 10),
                    title: Text(formatDate(snapshot.time)),
                    subtitle: Text(tr('{p0} 个文件', {'p0': snapshot.files})),
                    trailing: Text(formatBytes(snapshot.bytes)),
                  ),
              ],
            ),
    );
  }

  Widget _summary(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final latest = _history.last;
    final previous = _history.length > 1 ? _history[_history.length - 2] : null;
    final delta = previous == null ? 0 : latest.bytes - previous.bytes;
    final sign = delta > 0 ? '+' : '';
    final deltaColor = delta > 0
        ? scheme.error
        : (delta < 0 ? scheme.primary : scheme.onSurfaceVariant);

    return Card(
      elevation: 0,
      color: scheme.primaryContainer.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              formatBytes(latest.bytes),
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(tr('当前：{p0} 个文件', {'p0': latest.files})),
            if (previous != null) ...[
              const SizedBox(height: 4),
              Text(
                tr('较上次：{sign}{p1}{p2}', {'sign': sign, 'p1': formatBytes(delta.abs()), 'p2': delta < 0 ? tr('（减少）') : (delta > 0 ? tr('（增加）') : '')}),
                style: TextStyle(color: deltaColor),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chart(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxBytes = _history
        .map((s) => s.bytes)
        .fold<int>(0, (a, b) => a > b ? a : b);
    return SizedBox(
      height: 140,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final barWidth =
              (constraints.maxWidth / _history.length).clamp(4.0, 48.0);
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final snapshot in _history)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Container(
                      width: barWidth,
                      height: maxBytes == 0
                          ? 4
                          : (snapshot.bytes / maxBytes * 120).clamp(4.0, 120.0),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.75),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
