import 'package:flutter/foundation.dart';

/// 复制 / 剪贴板状态，供跨目录粘贴使用。
class TransferClipboard extends ChangeNotifier {
  TransferClipboard._();

  static final TransferClipboard instance = TransferClipboard._();

  List<String> _paths = const [];
  bool _isMove = false;

  List<String> get paths => _paths;
  bool get isMove => _isMove;
  bool get isEmpty => _paths.isEmpty;
  int get count => _paths.length;

  void set(List<String> paths, {required bool move}) {
    _paths = List.unmodifiable(paths);
    _isMove = move;
    notifyListeners();
  }

  void clear() {
    if (_paths.isEmpty) return;
    _paths = const [];
    notifyListeners();
  }
}
