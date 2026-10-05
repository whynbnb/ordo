import 'package:flutter/material.dart';

import 'prefs_store.dart';

/// 主题模式。
enum OrdoThemeMode { system, light, dark, black }

/// 预设主色。
const List<Color> ordoSeedColors = [
  Color(0xFF3D5AFE),
  Color(0xFF6750A4),
  Color(0xFF00695C),
  Color(0xFF2E7D32),
  Color(0xFFEF6C00),
  Color(0xFFC62828),
  Color(0xFFAD1457),
  Color(0xFF00838F),
  Color(0xFF455A64),
];

OrdoThemeMode _parseMode(String? raw) => switch (raw) {
  'light' => OrdoThemeMode.light,
  'dark' => OrdoThemeMode.dark,
  'black' => OrdoThemeMode.black,
  _ => OrdoThemeMode.system,
};

Color? _parseColor(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  var hex = raw.replaceFirst('#', '');
  if (hex.length == 6) hex = 'ff$hex';
  final value = int.tryParse(hex, radix: 16);
  return value == null ? null : Color(value);
}

String _colorHex(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';

/// 主题与主色偏好。
class ThemeStore extends ChangeNotifier {
  ThemeStore._();

  static final ThemeStore instance = ThemeStore._();

  static const Color _defaultSeed = Color(0xFF3D5AFE);

  OrdoThemeMode _mode = OrdoThemeMode.system;
  Color _seed = _defaultSeed;
  bool _loaded = false;

  OrdoThemeMode get mode => _mode;
  Color get seed => _seed;
  bool get loaded => _loaded;

  Future<void> load() async {
    await PrefsStore.instance.loadIfNeeded();
    _mode = _parseMode(PrefsStore.instance.value('theme_mode'));
    _seed = _parseColor(PrefsStore.instance.value('theme_color')) ?? _defaultSeed;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setMode(OrdoThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    await PrefsStore.instance.setValue('theme_mode', mode.name);
  }

  Future<void> setSeed(Color color) async {
    _seed = color;
    notifyListeners();
    await PrefsStore.instance.setValue('theme_color', _colorHex(color));
  }

  ThemeMode get materialThemeMode => switch (_mode) {
    OrdoThemeMode.light => ThemeMode.light,
    OrdoThemeMode.dark || OrdoThemeMode.black => ThemeMode.dark,
    OrdoThemeMode.system => ThemeMode.system,
  };

  bool get isBlack => _mode == OrdoThemeMode.black;
}
