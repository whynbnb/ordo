import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ordo/src/state/session_store.dart';

void main() {
  group('会话序列化', () {
    test('round trip', () {
      const session = BrowserSession(
        tabs: [
          TabSession(
            path: '/sdcard/A',
            title: 'A',
            history: [
              NavStep('/sdcard/A', 'A'),
              NavStep('/sdcard/A/b', 'b'),
            ],
            index: 1,
          ),
          TabSession(
            path: '/sdcard/B',
            title: 'B',
            history: [NavStep('/sdcard/B', 'B')],
            index: 0,
          ),
        ],
        active: 1,
      );

      final restored = BrowserSession.fromJson(
        jsonDecode(jsonEncode(session.toJson())),
      );

      expect(restored, isNotNull);
      expect(restored!.tabs.length, 2);
      expect(restored.tabs[0].history.length, 2);
      expect(restored.tabs[0].history[1].path, '/sdcard/A/b');
      expect(restored.tabs[0].index, 1);
      expect(restored.tabs[1].title, 'B');
      expect(restored.active, 1);
    });

    test('tolerates malformed data', () {
      expect(BrowserSession.fromJson(null), isNull);
      expect(BrowserSession.fromJson('nope'), isNull);
      expect(BrowserSession.fromJson({'tabs': []}), isNull);
      expect(TabSession.fromJson('x').path, '');
      expect(NavStep.fromJson(42).title, '');
    });
  });
}
