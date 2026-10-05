import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services/ordo_service.dart';
import '../state/saved_searches.dart';
import 'entry_tile.dart';
import 'open_entry.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.root, required this.title});

  final String root;
  final String title;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final OrdoService _service = OrdoService.instance;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  Timer? _debounce;
  int _requestId = 0;
  bool _searching = false;
  String? _error;
  SearchOutcome? _outcome;
  SearchOptions _options = SearchOptions.none;

  @override
  void initState() {
    super.initState();
    SavedSearchStore.instance.loadIfNeeded();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focusNode.requestFocus(),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty && !_options.hasFilters) {
      setState(() {
        _outcome = null;
        _error = null;
        _searching = false;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _run(value.trim()),
    );
  }

  Future<void> _run(String query) async {
    final requestId = ++_requestId;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final outcome = await _service.searchFiltered(
        widget.root,
        query,
        _options,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _outcome = outcome;
        _searching = false;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = '$error';
        _searching = false;
      });
    }
  }

  void _rerun() => _run(_textController.text.trim());

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<SearchOptions>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _FilterSheet(initial: _options),
    );
    if (result == null || !mounted) return;
    setState(() => _options = result);
    _rerun();
  }

  Future<void> _saveSearch() async {
    final query = _textController.text.trim();
    if (query.isEmpty && !_options.hasFilters) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('请先输入关键词或设置过滤条件')));
      return;
    }
    final controller = TextEditingController(text: query);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('保存搜索'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    await SavedSearchStore.instance.add(
      name: name,
      root: widget.root,
      query: query,
      options: _options,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已保存「$name」')));
  }

  Future<void> _showSaved() async {
    await SavedSearchStore.instance.loadIfNeeded();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => ListenableBuilder(
        listenable: SavedSearchStore.instance,
        builder: (context, _) {
          final items = SavedSearchStore.instance.items
              .where((item) => item.root == widget.root)
              .toList();
          if (items.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('暂无保存的搜索')),
            );
          }
          return ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                dense: true,
                title: Text('已保存的搜索'),
              ),
              for (final item in items)
                ListTile(
                  leading: const Icon(Icons.bookmark_outline_rounded),
                  title: Text(item.name),
                  subtitle: Text(
                    item.query.isEmpty
                        ? _describe(item.options)
                        : '${item.query} · ${_describe(item.options)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _applySaved(item);
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () =>
                        SavedSearchStore.instance.remove(item.id),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  String _describe(SearchOptions options) {
    final parts = <String>[];
    if (options.kind == 'file') parts.add('文件');
    if (options.kind == 'dir') parts.add('文件夹');
    if (options.extensions.isNotEmpty) parts.add(options.extensions.join('/'));
    if (options.minSize > 0) parts.add('≥${options.minSize ~/ (1024 * 1024)}MB');
    if (options.maxSize > 0) parts.add('≤${options.maxSize ~/ (1024 * 1024)}MB');
    if (options.after > 0) parts.add('按日期');
    if (options.content) parts.add('含内容');
    if (options.skipHidden) parts.add('忽略隐藏');
    return parts.isEmpty ? '全部' : parts.join(' · ');
  }

  void _applySaved(SavedSearch item) {
    _textController.text = item.query;
    setState(() => _options = item.options);
    _run(item.query);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _textController,
          focusNode: _focusNode,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: '在「${widget.title}」中搜索',
          ),
          onChanged: _onChanged,
          onSubmitted: (value) => _run(value.trim()),
        ),
        actions: [
          if (_textController.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close_rounded),
              onPressed: () {
                _textController.clear();
                _onChanged('');
              },
            ),
          IconButton(
            tooltip: '过滤',
            icon: Badge(
              isLabelVisible: _options.hasFilters,
              child: const Icon(Icons.tune_rounded),
            ),
            onPressed: _openFilters,
          ),
          IconButton(
            tooltip: '保存搜索',
            icon: const Icon(Icons.bookmark_add_outlined),
            onPressed: _saveSearch,
          ),
          IconButton(
            tooltip: '已保存',
            icon: const Icon(Icons.bookmarks_outlined),
            onPressed: _showSaved,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    final outcome = _outcome;
    if (outcome == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_rounded,
              size: 56,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              '输入关键词开始搜索',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    if (outcome.entries.isEmpty) {
      return Center(
        child: Text(
          '没有找到匹配的文件',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      children: [
        if (outcome.truncated || outcome.content)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              [
                if (outcome.content) '包含内容匹配',
                if (outcome.truncated)
                  '结果过多，仅显示前 ${outcome.entries.length} 项',
              ].join(' · '),
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: outcome.entries.length,
            itemBuilder: (context, index) {
              final entry = outcome.entries[index];
              return EntryTile(
                entry: entry,
                selectionMode: false,
                selected: false,
                onTap: () => openEntry(
                  context,
                  entry,
                  onReturn: () {
                    if (_textController.text.trim().isNotEmpty ||
                        _options.hasFilters) {
                      _rerun();
                    }
                  },
                ),
                onLongPress: () => openEntry(context, entry),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.initial});

  final SearchOptions initial;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late String _kind = widget.initial.kind;
  late final TextEditingController _extensions = TextEditingController(
    text: widget.initial.extensions.join(', '),
  );
  late final TextEditingController _minMb = TextEditingController(
    text: widget.initial.minSize > 0
        ? (widget.initial.minSize / (1024 * 1024)).toStringAsFixed(2)
        : '',
  );
  late final TextEditingController _maxMb = TextEditingController(
    text: widget.initial.maxSize > 0
        ? (widget.initial.maxSize / (1024 * 1024)).toStringAsFixed(2)
        : '',
  );
  late int _days = _daysFromAfter(widget.initial.after);
  late bool _content = widget.initial.content;
  late bool _skipHidden = widget.initial.skipHidden;

  static int _daysFromAfter(int after) {
    if (after <= 0) return 0;
    final diff = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(after * 1000),
    );
    final days = diff.inDays;
    if (days <= 1) return 1;
    if (days <= 7) return 7;
    if (days <= 30) return 30;
    if (days <= 365) return 365;
    return 0;
  }

  @override
  void dispose() {
    _extensions.dispose();
    _minMb.dispose();
    _maxMb.dispose();
    super.dispose();
  }

  double? _parseMb(String text) => double.tryParse(text.trim());

  void _apply() {
    final extensions = _extensions.text
        .split(RegExp(r'[,，\s]+'))
        .map((e) => e.trim().replaceFirst(RegExp(r'^\.'), ''))
        .where((e) => e.isNotEmpty)
        .toList();
    final minMb = _parseMb(_minMb.text);
    final maxMb = _parseMb(_maxMb.text);
    final after = _days <= 0
        ? 0
        : DateTime.now()
              .subtract(Duration(days: _days))
              .millisecondsSinceEpoch ~/
          1000;
    Navigator.pop(
      context,
      SearchOptions(
        minSize: minMb == null || minMb <= 0
            ? 0
            : (minMb * 1024 * 1024).round(),
        maxSize: maxMb == null || maxMb <= 0
            ? 0
            : (maxMb * 1024 * 1024).round(),
        after: after,
        extensions: extensions,
        kind: _kind,
        content: _content,
        skipHidden: _skipHidden,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '过滤条件',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text('类型', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'any', label: Text('全部')),
                ButtonSegment(value: 'file', label: Text('文件')),
                ButtonSegment(value: 'dir', label: Text('文件夹')),
              ],
              selected: {_kind},
              onSelectionChanged: (value) =>
                  setState(() => _kind = value.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _extensions,
              decoration: const InputDecoration(
                labelText: '扩展名（逗号分隔）',
                hintText: '如 jpg, png, pdf',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _minMb,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '最小 (MB)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _maxMb,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '最大 (MB)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _days,
              decoration: const InputDecoration(
                labelText: '修改时间',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 0, child: Text('不限')),
                DropdownMenuItem(value: 1, child: Text('今天')),
                DropdownMenuItem(value: 7, child: Text('近 7 天')),
                DropdownMenuItem(value: 30, child: Text('近 30 天')),
                DropdownMenuItem(value: 365, child: Text('近一年')),
              ],
              onChanged: (value) => setState(() => _days = value ?? 0),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('搜索文件内容'),
              subtitle: const Text('仅文本类文件，单文件上限 2MB'),
              value: _content,
              onChanged: (value) => setState(() => _content = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('忽略隐藏文件'),
              value: _skipHidden,
              onChanged: (value) => setState(() => _skipHidden = value),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, SearchOptions.none),
                    child: const Text('重置'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _apply,
                    child: const Text('应用'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
