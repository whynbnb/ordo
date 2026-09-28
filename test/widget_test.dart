import 'package:flutter_test/flutter_test.dart';
import 'package:ordo/src/core/format.dart';

void main() {
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
