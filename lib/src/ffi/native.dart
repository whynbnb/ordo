import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/ordo_exception.dart';
import '../i18n/i18n.dart';

// ---------------------------------------------------------------------------
// C ABI 类型
// ---------------------------------------------------------------------------

typedef _CStr = Pointer<Utf8>;

typedef _Native1 = _CStr Function(_CStr);
typedef _Dart1 = _CStr Function(_CStr);
typedef _Native2 = _CStr Function(_CStr, _CStr);
typedef _Dart2 = _CStr Function(_CStr, _CStr);
typedef _Native3 = _CStr Function(_CStr, _CStr, _CStr);
typedef _Dart3 = _CStr Function(_CStr, _CStr, _CStr);
typedef _NativeReadText = _CStr Function(_CStr, Uint64);
typedef _DartReadText = _CStr Function(_CStr, int);
typedef _NativeSearch = _CStr Function(_CStr, _CStr, Uint32);
typedef _DartSearch = _CStr Function(_CStr, _CStr, int);
typedef _NativeVoidStr = Void Function(_CStr);
typedef _DartVoidStr = void Function(_CStr);
typedef _NativeZero = _CStr Function();
typedef _DartZero = _CStr Function();
typedef _NativeReadBytes = Pointer<Uint8> Function(_CStr, Pointer<UintPtr>);
typedef _NativeImportFd = _CStr Function(Int32, _CStr, _CStr);
typedef _DartImportFd = _CStr Function(int, _CStr, _CStr);
typedef _NativeDelete = _CStr Function(_CStr, Bool);
typedef _DartDelete = _CStr Function(_CStr, bool);
typedef _NativeCopyMove = _CStr Function(_CStr, _CStr, Uint64);
typedef _DartCopyMove = _CStr Function(_CStr, _CStr, int);
typedef _NativeJob = _CStr Function(Uint64);
typedef _DartJob = _CStr Function(int);
typedef _NativeThumbnail = Pointer<Uint8> Function(
  _CStr,
  Uint32,
  Pointer<UintPtr>,
);
typedef _DartThumbnail = Pointer<Uint8> Function(_CStr, int, Pointer<UintPtr>);
typedef _NativeAnalyze = _CStr Function(_CStr, Uint64);
typedef _DartAnalyze = _CStr Function(_CStr, int);
typedef _NativeStrU32 = _CStr Function(_CStr, Uint32);
typedef _DartStrU32 = _CStr Function(_CStr, int);
typedef _NativeU32Str2 = _CStr Function(Uint32, _CStr, _CStr);
typedef _DartU32Str2 = _CStr Function(int, _CStr, _CStr);
typedef _DartReadBytes = Pointer<Uint8> Function(_CStr, Pointer<UintPtr>);
typedef _NativeFreeBytes = Void Function(Pointer<Uint8>, UintPtr);
typedef _DartFreeBytes = void Function(Pointer<Uint8>, int);
typedef _NativeWriteBytes = _CStr Function(_CStr, Pointer<Uint8>, UintPtr);
typedef _DartWriteBytes = _CStr Function(_CStr, Pointer<Uint8>, int);
typedef _NativeArchiveCreate = _CStr Function(_CStr, _CStr, Uint64, _CStr);
typedef _DartArchiveCreate = _CStr Function(_CStr, _CStr, int, _CStr);
typedef _NativeArchiveExtract = _CStr Function(
  _CStr,
  _CStr,
  Uint64,
  _CStr,
  _CStr,
);
typedef _DartArchiveExtract = _CStr Function(
  _CStr,
  _CStr,
  int,
  _CStr,
  _CStr,
);

DynamicLibrary _openLibrary() {
  // 桌面端调试 / 测试时可用环境变量指定已编译的动态库路径。
  final override = Platform.environment['ORDO_CORE_LIB'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libordo_core.so');
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libordo_core.dylib');
  }
  if (Platform.isIOS) {
    return DynamicLibrary.process();
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('ordo_core.dll');
  }
  throw UnsupportedError(tr('当前平台不受支持'));
}

/// 每个 isolate 各自持有一份符号表（`static final` 在每个 isolate 内独立初始化）。
class _OrdoBindings {
  _OrdoBindings._(this._lib);

  static final _OrdoBindings instance = _OrdoBindings._(_openLibrary());

  final DynamicLibrary _lib;

  late final _Dart1 listDir = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_list_dir',
  );
  late final _Dart1 stat = _lib.lookupFunction<_Native1, _Dart1>('ordo_stat');
  late final _DartReadText readText = _lib
      .lookupFunction<_NativeReadText, _DartReadText>('ordo_read_text');
  late final _Dart2 writeText = _lib.lookupFunction<_Native2, _Dart2>(
    'ordo_write_text',
  );
  late final _Dart1 createDir = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_create_dir',
  );
  late final _Dart1 createFile = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_create_file',
  );
  late final _DartDelete delete = _lib
      .lookupFunction<_NativeDelete, _DartDelete>('ordo_delete');
  late final _Dart2 rename = _lib.lookupFunction<_Native2, _Dart2>(
    'ordo_rename',
  );
  late final _DartCopyMove copy = _lib
      .lookupFunction<_NativeCopyMove, _DartCopyMove>('ordo_copy');
  late final _DartCopyMove move = _lib
      .lookupFunction<_NativeCopyMove, _DartCopyMove>('ordo_move');
  late final _DartSearch search = _lib
      .lookupFunction<_NativeSearch, _DartSearch>('ordo_search');
  late final _Dart3 searchFiltered = _lib
      .lookupFunction<_Native3, _Dart3>('ordo_search_filtered');
  late final _DartStrU32 cleanupScan = _lib
      .lookupFunction<_NativeStrU32, _DartStrU32>('ordo_cleanup_scan');
  late final _Dart1 trendRecord = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_trend_record',
  );
  late final _Dart1 trendHistory = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_trend_history',
  );
  late final _DartStrU32 secureDelete = _lib
      .lookupFunction<_NativeStrU32, _DartStrU32>('ordo_secure_delete');
  late final _Dart1 vaultMove = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_vault_move',
  );
  late final _DartZero vaultList = _lib.lookupFunction<_NativeZero, _DartZero>(
    'ordo_vault_list',
  );
  late final _Dart2 vaultRestore = _lib.lookupFunction<_Native2, _Dart2>(
    'ordo_vault_restore',
  );
  late final _Dart1 vaultDelete = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_vault_delete',
  );
  late final _Dart1 crashAppend = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_crash_append',
  );
  late final _DartZero crashRead = _lib.lookupFunction<_NativeZero, _DartZero>(
    'ordo_crash_read',
  );
  late final _DartZero crashClear = _lib
      .lookupFunction<_NativeZero, _DartZero>('ordo_crash_clear');
  late final _DartZero storageRoots = _lib
      .lookupFunction<_NativeZero, _DartZero>('ordo_storage_roots');
  late final _DartZero ping = _lib.lookupFunction<_NativeZero, _DartZero>(
    'ordo_ping',
  );
  late final _DartVoidStr freeString = _lib
      .lookupFunction<_NativeVoidStr, _DartVoidStr>('ordo_free_string');
  late final _DartReadBytes readBytes = _lib
      .lookupFunction<_NativeReadBytes, _DartReadBytes>('ordo_read_bytes');
  late final _DartFreeBytes freeBytes = _lib
      .lookupFunction<_NativeFreeBytes, _DartFreeBytes>('ordo_free_bytes');
  late final _DartWriteBytes writeBytes = _lib
      .lookupFunction<_NativeWriteBytes, _DartWriteBytes>('ordo_write_bytes');
  late final _Dart2 configInit = _lib.lookupFunction<_Native2, _Dart2>(
    'ordo_config_init',
  );
  late final _DartU32Str2 privConfigure = _lib
      .lookupFunction<_NativeU32Str2, _DartU32Str2>('ordo_priv_configure');
  late final _DartZero privClear = _lib.lookupFunction<_NativeZero, _DartZero>(
    'ordo_priv_clear',
  );
  late final _DartZero privStatus = _lib
      .lookupFunction<_NativeZero, _DartZero>('ordo_priv_status');
  late final _DartZero profileList = _lib
      .lookupFunction<_NativeZero, _DartZero>('ordo_profile_list');
  late final _Dart1 profileSave = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_profile_save',
  );
  late final _Dart1 profileRemove = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_profile_remove',
  );
  late final _Dart1 profileTest = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_profile_test',
  );
  late final _Dart1 netDisconnect = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_net_disconnect',
  );
  late final _Dart1 netDownload = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_net_download',
  );
  late final _Dart1 storageHints = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_storage_hints',
  );
  late final _Dart1 serverStart = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_server_start',
  );
  late final _DartZero serverStop = _lib.lookupFunction<_NativeZero, _DartZero>(
    'ordo_server_stop',
  );
  late final _DartZero serverStatus = _lib
      .lookupFunction<_NativeZero, _DartZero>('ordo_server_status');
  late final _Dart1 serverConfigSave = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_server_config_save',
  );
  late final _DartZero serverConfigLoad = _lib
      .lookupFunction<_NativeZero, _DartZero>('ordo_server_config_load');
  late final _DartZero serverLog = _lib.lookupFunction<_NativeZero, _DartZero>(
    'ordo_server_log',
  );
  late final _DartZero serverLogClear = _lib
      .lookupFunction<_NativeZero, _DartZero>('ordo_server_log_clear');
  late final _DartImportFd importFd = _lib
      .lookupFunction<_NativeImportFd, _DartImportFd>('ordo_import_fd');
  late final _DartZero favoriteList = _lib
      .lookupFunction<_NativeZero, _DartZero>('ordo_favorite_list');
  late final _Dart2 favoriteAdd = _lib.lookupFunction<_Native2, _Dart2>(
    'ordo_favorite_add',
  );
  late final _Dart1 favoriteRemove = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_favorite_remove',
  );
  late final _DartZero prefAll = _lib.lookupFunction<_NativeZero, _DartZero>(
    'ordo_pref_all',
  );
  late final _Dart2 prefSet = _lib.lookupFunction<_Native2, _Dart2>(
    'ordo_pref_set',
  );
  late final _Dart1 prefRemove = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_pref_remove',
  );
  late final _DartZero trashList = _lib.lookupFunction<_NativeZero, _DartZero>(
    'ordo_trash_list',
  );
  late final _Dart1 trashRestore = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_trash_restore',
  );
  late final _DartZero trashEmpty = _lib.lookupFunction<_NativeZero, _DartZero>(
    'ordo_trash_empty',
  );
  late final _Dart1 trashRemove = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_trash_remove',
  );
  late final _DartZero jobCreate = _lib.lookupFunction<_NativeZero, _DartZero>(
    'ordo_job_create',
  );
  late final _DartJob jobStatus = _lib.lookupFunction<_NativeJob, _DartJob>(
    'ordo_job_status',
  );
  late final _DartJob jobCancel = _lib.lookupFunction<_NativeJob, _DartJob>(
    'ordo_job_cancel',
  );
  late final _DartJob jobCleanup = _lib.lookupFunction<_NativeJob, _DartJob>(
    'ordo_job_cleanup',
  );
  late final _DartArchiveCreate archiveCreate = _lib
      .lookupFunction<_NativeArchiveCreate, _DartArchiveCreate>(
        'ordo_archive_create',
      );
  late final _DartArchiveExtract archiveExtract = _lib
      .lookupFunction<_NativeArchiveExtract, _DartArchiveExtract>(
        'ordo_archive_extract',
      );
  late final _Dart1 archiveList = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_archive_list',
  );
  late final _DartThumbnail thumbnail = _lib
      .lookupFunction<_NativeThumbnail, _DartThumbnail>('ordo_thumbnail');
  late final _DartAnalyze analyze = _lib
      .lookupFunction<_NativeAnalyze, _DartAnalyze>('ordo_analyze');
  late final _Dart2 hash = _lib.lookupFunction<_Native2, _Dart2>('ordo_hash');
  late final _Dart1 dirSize = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_dir_size',
  );
  late final _Dart2 symlink = _lib.lookupFunction<_Native2, _Dart2>(
    'ordo_symlink',
  );
  late final _Dart1 mediaInfo = _lib.lookupFunction<_Native1, _Dart1>(
    'ordo_media_info',
  );
  late final _Dart2 imageRotate = _lib.lookupFunction<_Native2, _Dart2>(
    'ordo_image_rotate',
  );
  late final _Dart2 copyFile = _lib.lookupFunction<_Native2, _Dart2>(
    'ordo_copy_file',
  );
  late final _DartThumbnail qrPng = _lib
      .lookupFunction<_NativeThumbnail, _DartThumbnail>('ordo_qr_png');
}

// ---------------------------------------------------------------------------
// 执行入口（可在任意 isolate 中调用）
// ---------------------------------------------------------------------------

/// 根据操作名调用原生核心并返回已解码的 `data` 字段。
///
/// 参数与返回值都必须是可跨 isolate 传递的类型（String / int / bool /
/// List / Map / Uint8List）。
dynamic nativeExecute(String op, List<Object?> args) {
  final bindings = _OrdoBindings.instance;
  switch (op) {
    case 'ping':
      return _decode(_take(bindings, bindings.ping()));
    case 'privConfigure':
      return _decode(
        _take(
          bindings,
          _withCString(args[1] as String, (token) {
            return _withCString(
              args[2] as String,
              (mode) => bindings.privConfigure(args[0] as int, token, mode),
            );
          }),
        ),
      );
    case 'privClear':
      return _decode(_take(bindings, bindings.privClear()));
    case 'privStatus':
      return _decode(_take(bindings, bindings.privStatus()));
    case 'listDir':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (p) => bindings.listDir(p)),
        ),
      );
    case 'stat':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (p) => bindings.stat(p)),
        ),
      );
    case 'readText':
      return _decode(
        _take(
          bindings,
          _withCString(
            args[0] as String,
            (p) => bindings.readText(p, args[1] as int),
          ),
        ),
      );
    case 'writeText':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (path) {
            return _withCString(args[1] as String, (content) {
              return bindings.writeText(path, content);
            });
          }),
        ),
      );
    case 'createDir':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (p) => bindings.createDir(p)),
        ),
      );
    case 'createFile':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (p) => bindings.createFile(p)),
        ),
      );
    case 'delete':
      return _decode(
        _take(
          bindings,
          _withCString(
            args[0] as String,
            (p) => bindings.delete(p, args[1] as bool),
          ),
        ),
      );
    case 'rename':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (path) {
            return _withCString(
              args[1] as String,
              (name) => bindings.rename(path, name),
            );
          }),
        ),
      );
    case 'copy':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (sources) {
            return _withCString(
              args[1] as String,
              (dest) => bindings.copy(sources, dest, args[2] as int),
            );
          }),
        ),
      );
    case 'move':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (sources) {
            return _withCString(
              args[1] as String,
              (dest) => bindings.move(sources, dest, args[2] as int),
            );
          }),
        ),
      );
    case 'search':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (root) {
            return _withCString(args[1] as String, (query) {
              return bindings.search(root, query, args[2] as int);
            });
          }),
        ),
      );
    case 'searchFiltered':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (root) {
            return _withCString(args[1] as String, (query) {
              return _withCString(
                args[2] as String,
                (options) => bindings.searchFiltered(root, query, options),
              );
            });
          }),
        ),
      );
    case 'cleanupScan':
      return _decode(
        _take(
          bindings,
          _withCString(
            args[0] as String,
            (root) => bindings.cleanupScan(root, args[1] as int),
          ),
        ),
      );
    case 'trendRecord':
      return _decode(
        _take(
          bindings,
          _withCString(
            args[0] as String,
            (root) => bindings.trendRecord(root),
          ),
        ),
      );
    case 'trendHistory':
      return _decode(
        _take(
          bindings,
          _withCString(
            args[0] as String,
            (root) => bindings.trendHistory(root),
          ),
        ),
      );
    case 'secureDelete':
      return _decode(
        _take(
          bindings,
          _withCString(
            args[0] as String,
            (paths) => bindings.secureDelete(paths, args[1] as int),
          ),
        ),
      );
    case 'vaultMove':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (paths) => bindings.vaultMove(paths)),
        ),
      );
    case 'vaultList':
      return _decode(_take(bindings, bindings.vaultList()));
    case 'vaultRestore':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (names) {
            return _withCString(
              args[1] as String,
              (dest) => bindings.vaultRestore(names, dest),
            );
          }),
        ),
      );
    case 'vaultDelete':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (names) => bindings.vaultDelete(names)),
        ),
      );
    case 'crashAppend':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (text) => bindings.crashAppend(text)),
        ),
      );
    case 'crashRead':
      return _decode(_take(bindings, bindings.crashRead()));
    case 'crashClear':
      return _decode(_take(bindings, bindings.crashClear()));
    case 'storageRoots':
      return _decode(_take(bindings, bindings.storageRoots()));
    case 'storageHints':
      return _decode(
        _take(
          bindings,
          _withCString(
            args[0] as String,
            (json) => bindings.storageHints(json),
          ),
        ),
      );
    case 'serverStart':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (json) => bindings.serverStart(json)),
        ),
      );
    case 'serverStop':
      return _decode(_take(bindings, bindings.serverStop()));
    case 'serverStatus':
      return _decode(_take(bindings, bindings.serverStatus()));
    case 'serverConfigSave':
      return _decode(
        _take(
          bindings,
          _withCString(
            args[0] as String,
            (json) => bindings.serverConfigSave(json),
          ),
        ),
      );
    case 'serverConfigLoad':
      return _decode(_take(bindings, bindings.serverConfigLoad()));
    case 'serverLog':
      return _decode(_take(bindings, bindings.serverLog()));
    case 'serverLogClear':
      return _decode(_take(bindings, bindings.serverLogClear()));
    case 'importFd':
      return _decode(
        _take(
          bindings,
          _withCString(args[1] as String, (dir) {
            return _withCString(
              args[2] as String,
              (name) => bindings.importFd(args[0] as int, dir, name),
            );
          }),
        ),
      );
    case 'favoriteList':
      return _decode(_take(bindings, bindings.favoriteList()));
    case 'favoriteAdd':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (name) {
            return _withCString(
              args[1] as String,
              (path) => bindings.favoriteAdd(name, path),
            );
          }),
        ),
      );
    case 'favoriteRemove':
      return _decode(
        _take(
          bindings,
          _withCString(
            args[0] as String,
            (path) => bindings.favoriteRemove(path),
          ),
        ),
      );
    case 'prefAll':
      return _decode(_take(bindings, bindings.prefAll()));
    case 'prefSet':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (key) {
            return _withCString(
              args[1] as String,
              (value) => bindings.prefSet(key, value),
            );
          }),
        ),
      );
    case 'prefRemove':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (key) => bindings.prefRemove(key)),
        ),
      );
    case 'trashList':
      return _decode(_take(bindings, bindings.trashList()));
    case 'trashRestore':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (ids) => bindings.trashRestore(ids)),
        ),
      );
    case 'trashEmpty':
      return _decode(_take(bindings, bindings.trashEmpty()));
    case 'trashRemove':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (ids) => bindings.trashRemove(ids)),
        ),
      );
    case 'jobCreate':
      return _decode(_take(bindings, bindings.jobCreate()));
    case 'jobStatus':
      return _decode(_take(bindings, bindings.jobStatus(args[0] as int)));
    case 'jobCancel':
      return _decode(_take(bindings, bindings.jobCancel(args[0] as int)));
    case 'jobCleanup':
      return _decode(_take(bindings, bindings.jobCleanup(args[0] as int)));
    case 'archiveCreate':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (sources) {
            return _withCString(args[1] as String, (dest) {
              return _withCString(
                args[3] as String,
                (password) => bindings.archiveCreate(
                  sources,
                  dest,
                  args[2] as int,
                  password,
                ),
              );
            });
          }),
        ),
      );
    case 'archiveExtract':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (archive) {
            return _withCString(args[1] as String, (dest) {
              return _withCString(args[3] as String, (password) {
                return _withCString(
                  args[4] as String,
                  (only) => bindings.archiveExtract(
                    archive,
                    dest,
                    args[2] as int,
                    password,
                    only,
                  ),
                );
              });
            });
          }),
        ),
      );
    case 'archiveList':
      return _decode(
        _take(
          bindings,
          _withCString(
            args[0] as String,
            (archive) => bindings.archiveList(archive),
          ),
        ),
      );
    case 'analyze':
      return _decode(
        _take(
          bindings,
          _withCString(
            args[0] as String,
            (root) => bindings.analyze(root, args[1] as int),
          ),
        ),
      );
    case 'hash':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (path) {
            return _withCString(
              args[1] as String,
              (algorithm) => bindings.hash(path, algorithm),
            );
          }),
        ),
      );
    case 'dirSize':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (path) => bindings.dirSize(path)),
        ),
      );
    case 'symlink':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (target) {
            return _withCString(
              args[1] as String,
              (link) => bindings.symlink(target, link),
            );
          }),
        ),
      );
    case 'mediaInfo':
      return _decode(
        _take(
          bindings,
          _withCString(
            args[0] as String,
            (path) => bindings.mediaInfo(path),
          ),
        ),
      );
    case 'imageRotate':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (path) {
            return _withCString(
              args[1] as String,
              (direction) => bindings.imageRotate(path, direction),
            );
          }),
        ),
      );
    case 'copyFile':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (source) {
            return _withCString(
              args[1] as String,
              (dest) => bindings.copyFile(source, dest),
            );
          }),
        ),
      );
    case 'qrPng':
      return _qrPng(bindings, args[0] as String, args[1] as int);
    case 'readBytes':
      return _readBytes(bindings, args[0] as String);
    case 'thumbnail':
      return _thumbnail(bindings, args[0] as String, args[1] as int);
    case 'writeBytes':
      return _writeBytes(bindings, args[0] as String, args[1] as Uint8List);
    case 'configInit':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (dir) {
            return _withCString(
              args[1] as String,
              (cache) => bindings.configInit(dir, cache),
            );
          }),
        ),
      );
    case 'profileList':
      return _decode(_take(bindings, bindings.profileList()));
    case 'profileSave':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (json) => bindings.profileSave(json)),
        ),
      );
    case 'profileRemove':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (id) => bindings.profileRemove(id)),
        ),
      );
    case 'profileTest':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (json) => bindings.profileTest(json)),
        ),
      );
    case 'netDisconnect':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (id) => bindings.netDisconnect(id)),
        ),
      );
    case 'netDownload':
      return _decode(
        _take(
          bindings,
          _withCString(args[0] as String, (uri) => bindings.netDownload(uri)),
        ),
      );
    default:
      throw OrdoException(tr('未知操作：{op}', {'op': op}));
  }
}

String _take(_OrdoBindings bindings, Pointer<Utf8> ptr) {
  if (ptr == nullptr) {
    throw OrdoException(tr('原生核心返回空指针'));
  }
  try {
    return ptr.toDartString();
  } finally {
    bindings.freeString(ptr);
  }
}

T _withCString<T>(String value, T Function(Pointer<Utf8>) body) {
  final ptr = value.toNativeUtf8();
  try {
    return body(ptr);
  } finally {
    malloc.free(ptr);
  }
}

dynamic _decode(String raw) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    throw OrdoException(tr('无法解析原生核心返回的数据'));
  }
  if (decoded is Map && decoded['ok'] == true) {
    return decoded['data'];
  }
  final message = decoded is Map ? decoded['error']?.toString() : null;
  throw OrdoException(message ?? tr('原生核心返回未知错误'));
}

Uint8List _readBytes(_OrdoBindings bindings, String path) {
  final outLen = malloc.allocate<UintPtr>(sizeOf<UintPtr>());
  try {
    final pointer = _withCString(path, (p) => bindings.readBytes(p, outLen));
    final length = outLen.value;
    if (pointer == nullptr) {
      throw OrdoException(tr('无法读取文件内容'));
    }
    if (length == 0) {
      return Uint8List(0);
    }
    final bytes = Uint8List.fromList(pointer.asTypedList(length));
    bindings.freeBytes(pointer, length);
    return bytes;
  } finally {
    malloc.free(outLen);
  }
}

Uint8List? _thumbnail(_OrdoBindings bindings, String path, int maxPx) {
  final outLen = malloc.allocate<UintPtr>(sizeOf<UintPtr>());
  try {
    final pointer = _withCString(
      path,
      (p) => bindings.thumbnail(p, maxPx, outLen),
    );
    final length = outLen.value;
    if (pointer == nullptr || length == 0) {
      return null;
    }
    final bytes = Uint8List.fromList(pointer.asTypedList(length));
    bindings.freeBytes(pointer, length);
    return bytes;
  } finally {
    malloc.free(outLen);
  }
}

Uint8List? _qrPng(_OrdoBindings bindings, String text, int scale) {
  final outLen = malloc.allocate<UintPtr>(sizeOf<UintPtr>());
  try {
    final pointer = _withCString(
      text,
      (p) => bindings.qrPng(p, scale, outLen),
    );
    final length = outLen.value;
    if (pointer == nullptr || length == 0) {
      return null;
    }
    final bytes = Uint8List.fromList(pointer.asTypedList(length));
    bindings.freeBytes(pointer, length);
    return bytes;
  } finally {
    malloc.free(outLen);
  }
}

dynamic _writeBytes(_OrdoBindings bindings, String path, Uint8List data) {
  if (data.isEmpty) {
    return _decode(
      _take(
        bindings,
        _withCString(path, (p) => bindings.writeBytes(p, nullptr, 0)),
      ),
    );
  }
  final buffer = malloc.allocate<Uint8>(data.length);
  buffer.asTypedList(data.length).setAll(0, data);
  try {
    return _decode(
      _take(
        bindings,
        _withCString(path, (p) => bindings.writeBytes(p, buffer, data.length)),
      ),
    );
  } finally {
    malloc.free(buffer);
  }
}
