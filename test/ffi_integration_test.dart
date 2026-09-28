import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ordo/src/core/models.dart';
import 'package:ordo/src/services/ordo_service.dart';

/// 端到端验证 Dart <-> Rust 的 C ABI。
///
/// 需要先构建本机动态库并指定路径：
///   cargo build --manifest-path rust/Cargo.toml
///   ORDO_CORE_LIB=rust/target/debug/libordo_core.dylib flutter test test/ffi_integration_test.dart
void main() {
  final lib = Platform.environment['ORDO_CORE_LIB'];
  if (lib == null || lib.isEmpty) {
    test('跳过 FFI 集成测试', () {}, skip: '未设置 ORDO_CORE_LIB');
    return;
  }

  final service = OrdoService.instance;

  test('ping 返回核心信息', () async {
    final info = await service.ping();
    expect(info['name'], 'Ordo');
    expect(info['core'], 'ordo_core');
  });

  test('目录 / 文件 / 复制 / 重命名 / 删除 全流程', () async {
    final root = Directory.systemTemp.createTempSync('ordo_ffi_');
    addTearDown(() => root.deleteSync(recursive: true));

    final folder = await service.createDir('${root.path}/demo');
    expect(folder.isDir, isTrue);

    final file = await service.createFile('${root.path}/demo/note.txt');
    expect(file.isDir, isFalse);

    await service.writeText('${root.path}/demo/note.txt', '你好, Ordo');
    final content = await service.readText('${root.path}/demo/note.txt');
    expect(content.content, '你好, Ordo');

    final listing = await service.listDir('${root.path}/demo');
    expect(listing.map((e) => e.name), contains('note.txt'));

    final renamed = await service.rename(
      '${root.path}/demo/note.txt',
      'renamed.txt',
    );
    expect(renamed.name, 'renamed.txt');

    final dest = await service.createDir('${root.path}/dest');
    expect(dest.isDir, isTrue);

    final copy = await service.copy(['${root.path}/demo'], dest.path);
    expect(copy.done, 1);

    final results = await service.search(root.path, 'renamed');
    expect(results.entries.length, 2);

    final roots = await service.storageRoots();
    expect(roots, isA<List>());

    final deleted = await service.delete([
      '${root.path}/demo',
      '${root.path}/dest',
    ]);
    expect(deleted.deleted, 2);
    expect(deleted.errors, isEmpty);
  });

  test('读取原始字节', () async {
    final root = Directory.systemTemp.createTempSync('ordo_bytes_');
    addTearDown(() => root.deleteSync(recursive: true));

    final file = '${root.path}/bin.dat';
    final bytes = await service.writeBytes(
      file,
      Uint8List.fromList([1, 2, 3, 4, 5]),
    );
    expect(bytes.size, 5);

    final read = await service.readBytes(file);
    expect(read, [1, 2, 3, 4, 5]);
  });

  // 远程连接配置的增删查（不需要真实服务器）。
  test('连接配置可保存、读取、删除并持久化', () async {
    final dir = Directory.systemTemp.createTempSync('ordo_cfg_');
    addTearDown(() => dir.deleteSync(recursive: true));
    service.configInit(
      configDir: '${dir.path}/config',
      cacheDir: '${dir.path}/cache',
    );

    final initial = await service.profiles();
    expect(initial, isEmpty);

    final saved = await service.saveProfile(
      const ConnectionProfile(
        id: '',
        name: '测试 FTP',
        kind: 'ftp',
        host: '127.0.0.1',
        port: 21,
        username: 'user',
        password: 'pass',
        basePath: '/pub',
        share: '',
        domain: '',
        secure: false,
        insecureTls: false,
      ),
    );
    expect(saved.id, isNotEmpty);
    expect(saved.name, '测试 FTP');

    final listed = await service.profiles();
    expect(listed.length, 1);
    expect(listed.first.host, '127.0.0.1');

    await service.removeProfile(saved.id);
    expect(await service.profiles(), isEmpty);
  });
}
