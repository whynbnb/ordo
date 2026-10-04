import 'package:flutter/widgets.dart';

/// 全局路由观察者：用于判断当前可见页面，作为外部拖入的目标。
final RouteObserver<PageRoute<dynamic>> ordoRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
