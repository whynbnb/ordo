import 'package:flutter/material.dart';

import 'browser_screen.dart';
import '../i18n/i18n.dart';

/// 多标签文件浏览：每个标签拥有独立的导航栈（嵌套 Navigator）。
class TabbedBrowserScreen extends StatefulWidget {
  const TabbedBrowserScreen({
    super.key,
    required this.path,
    required this.title,
  });

  final String path;
  final String title;

  @override
  State<TabbedBrowserScreen> createState() => _TabbedBrowserScreenState();
}

class _Tab {
  _Tab({required this.path, required this.title});

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  String path;
  String title;
}

class _TabbedBrowserScreenState extends State<TabbedBrowserScreen> {
  late final List<_Tab> _tabs;
  int _active = 0;

  @override
  void initState() {
    super.initState();
    _tabs = [_Tab(path: widget.path, title: widget.title)];
  }

  void _addTab() {
    final current = _tabs[_active];
    setState(() {
      _tabs.add(_Tab(path: current.path, title: current.title));
      _active = _tabs.length - 1;
    });
  }

  void _closeTab(int index) {
    if (_tabs.length <= 1) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _tabs.removeAt(index);
      if (_active >= _tabs.length) _active = _tabs.length - 1;
    });
  }

  bool get _canPopNested =>
      _tabs[_active].navigatorKey.currentState?.canPop() ?? false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canPopNested,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _tabs[_active].navigatorKey.currentState?.maybePop();
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _active,
          children: [for (var i = 0; i < _tabs.length; i++) _buildTab(i)],
        ),
        bottomNavigationBar: _buildTabBar(context),
      ),
    );
  }

  Widget _buildTab(int index) {
    final tab = _tabs[index];
    return Navigator(
      key: tab.navigatorKey,
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => BrowserScreen(
          path: tab.path,
          title: tab.title,
          onLocationChanged: (path, title) {
            if (!mounted) return;
            setState(() {
              tab.path = path;
              tab.title = title;
            });
          },
        ),
      ),
    );
  }

  Widget _buildTabBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BottomAppBar(
      height: 48,
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _tabs.length,
              itemBuilder: (context, index) {
                final active = index == _active;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  child: Material(
                    color: active
                        ? scheme.secondaryContainer
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => setState(() => _active = index),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Text(
                              _tabs[index].title.isEmpty
                                  ? tr('浏览')
                                  : _tabs[index].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: active
                                    ? scheme.onSecondaryContainer
                                    : scheme.onSurfaceVariant,
                                fontWeight: active
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: () => _closeTab(index),
                              child: Icon(
                                Icons.close_rounded,
                                size: 16,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: tr('新建标签页'),
            icon: const Icon(Icons.add_rounded),
            onPressed: _addTab,
          ),
        ],
      ),
    );
  }
}
