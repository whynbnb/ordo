import 'package:flutter/material.dart';

import 'browser_screen.dart';
import '../state/session_store.dart';
import '../i18n/i18n.dart';

/// 多标签文件浏览：每个标签拥有独立的浏览页与页内历史。
///
/// 支持从会话恢复（[initialTabs]）——「首页 → 继续浏览」。
class TabbedBrowserScreen extends StatefulWidget {
  const TabbedBrowserScreen({
    super.key,
    this.path = '',
    this.title = '',
    this.initialTabs,
    this.initialActive = 0,
  });

  final String path;
  final String title;
  final List<TabSession>? initialTabs;
  final int initialActive;

  @override
  State<TabbedBrowserScreen> createState() => _TabbedBrowserScreenState();
}

class _Tab {
  _Tab({
    required this.path,
    required this.title,
    this.initialHistory,
    this.initialIndex = 0,
  });

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  final BrowserScreenController controller = BrowserScreenController();
  final List<NavStep>? initialHistory;
  final int initialIndex;
  String path;
  String title;
}

class _TabbedBrowserScreenState extends State<TabbedBrowserScreen> {
  late final List<_Tab> _tabs;
  int _active = 0;

  @override
  void initState() {
    super.initState();
    final restore = widget.initialTabs;
    if (restore != null && restore.isNotEmpty) {
      _tabs = [
        for (final tab in restore)
          _Tab(
            path: tab.path,
            title: tab.title,
            initialHistory: tab.history,
            initialIndex: tab.index,
          ),
      ];
      _active = widget.initialActive.clamp(0, _tabs.length - 1).toInt();
    } else {
      _tabs = [_Tab(path: widget.path, title: widget.title)];
      _active = 0;
    }
    for (final tab in _tabs) {
      tab.controller.addListener(_onTabChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recordSession();
    });
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.controller.removeListener(_onTabChanged);
      tab.controller.dispose();
    }
    // 不清除会话：回到首页后仍可在首页「继续浏览」。
    super.dispose();
  }

  void _onTabChanged() {
    // 页内历史变化：更新会话记录（返回能力由 PopScope 实时判断）。
    _recordSession();
  }

  void _recordSession() {
    final tabs = <TabSession>[];
    for (final tab in _tabs) {
      tabs.add(
        tab.controller.state ??
            TabSession(
              path: tab.path,
              title: tab.title,
              history: [NavStep(tab.path, tab.title)],
              index: 0,
            ),
      );
    }
    if (tabs.isEmpty) return;
    SessionStore.instance.record(
      BrowserSession(
        tabs: tabs,
        active: _active.clamp(0, tabs.length - 1).toInt(),
      ),
    );
  }

  void _addTab() {
    final current = _tabs[_active];
    setState(() {
      final tab = _Tab(path: current.path, title: current.title);
      tab.controller.addListener(_onTabChanged);
      _tabs.add(tab);
      _active = _tabs.length - 1;
    });
    _recordSession();
  }

  void _selectTab(int index) {
    if (index == _active) return;
    setState(() => _active = index);
    _recordSession();
  }

  void _closeTab(int index) {
    if (_tabs.length <= 1) {
      // 关闭唯一标签 = 返回上一页（首页）。直接 pop，避免再次经过 PopScope。
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      final tab = _tabs.removeAt(index);
      tab.controller.removeListener(_onTabChanged);
      tab.controller.dispose();
      if (_active >= _tabs.length) _active = _tabs.length - 1;
    });
    _recordSession();
  }

  /// 系统返回：先弹嵌套路由，再走页内历史，最后才回到首页。
  void _handleSystemBack() {
    final active = _tabs[_active];
    final nested = active.navigatorKey.currentState;
    if (nested != null && nested.canPop()) {
      nested.maybePop();
      return;
    }
    if (active.controller.canGoBack) {
      active.controller.goBack();
      return;
    }
    // 已经到标签页根部：直接返回首页（不能再用 maybePop，否则会重复进入本 PopScope）。
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleSystemBack();
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
          controller: tab.controller,
          initialHistory: tab.initialHistory,
          initialIndex: tab.initialIndex,
          onExit: () {
            if (mounted) Navigator.of(context).pop();
          },
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
                      onTap: () => _selectTab(index),
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
