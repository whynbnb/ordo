import 'package:flutter_test/flutter_test.dart';
import 'package:ordo/src/core/format.dart';
import 'package:ordo/src/i18n/i18n.dart';

void main() {
  group('i18n', () {
    test('english dictionary has common entries', () {
      expect(enTranslations['取消'], 'Cancel');
      expect(enTranslations['保存'], 'Save');
      expect(enTranslations['删除'], 'Delete');
      expect(
        enTranslations['启动失败：{error}'],
        'Start failed: {error}',
      );
    });

    test('rust error maps', () {
      expect(enErrorMessages['未找到'], 'Not found');
      expect(
        enErrorPrefixes.any((e) => e.$1 == '打开失败：'),
        isTrue,
      );
    });
  });

  group('formatBytes', () {
    test('formats common sizes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1024 * 1024 * 3), '3.0 MB');
    });
  });

  group('paths', () {
    test('joinPath', () {
      expect(
        joinPath('/storage/emulated/0', 'Download'),
        '/storage/emulated/0/Download',
      );
      expect(joinPath('/storage/emulated/0/', 'a'), '/storage/emulated/0/a');
    });

    test('parentOf', () {
      expect(parentOf('/storage/emulated/0/a'), '/storage/emulated/0');
      expect(parentOf('/a'), '/');
      expect(parentOf('/'), '/');
    });

    test('baseName', () {
      expect(baseName('/storage/emulated/0/a.txt'), 'a.txt');
      expect(baseName('/storage/emulated/0/'), '0');
    });

    test('breadcrumbs', () {
      final crumbs = breadcrumbs('/storage/emulated/0/a');
      expect(crumbs.length, 4);
      expect(crumbs.last, ('a', '/storage/emulated/0/a'));
    });
  });
}
