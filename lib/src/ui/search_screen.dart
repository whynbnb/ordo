import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services/ordo_service.dart';
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

  @override
  void initState() {
    super.initState();
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
    if (value.trim().isEmpty) {
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
      final outcome = await _service.search(widget.root, query);
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
        if (outcome.truncated)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('结果过多，仅显示前 ${outcome.entries.length} 项'),
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
                    final query = _textController.text.trim();
                    if (query.isNotEmpty) _run(query);
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
