import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../core/models.dart';
import '../ffi/native.dart';
import 'platform_service.dart';

/// Ordo 的文件系统门面。所有操作都经由 Rust 核心完成。
///
/// 轻量操作直接调用；可能耗时或阻塞的操作放到后台 isolate，避免卡住界面。
class OrdoService {
  OrdoService._();

  static final OrdoService instance = OrdoService._();

  static const int defaultReadLimit = 1024 * 1024; // 1 MB

  dynamic _direct(String op, [List<Object?> args = const []]) {
    return nativeExecute(op, args);
  }

  Future<dynamic> _background(String op, List<Object?> args) {
    return Isolate.run(() => nativeExecute(op, args));
  }

  /// 连通性检查，确认动态库可用。
  Future<Map<String, dynamic>> ping() async {
    final data = _direct('ping');
    return (data as Map).cast<String, dynamic>();
  }

  Future<List<FileEntry>> listDir(String path) async {
    final data = await _background('listDir', [path]);
    return (data as List)
        .map((e) => FileEntry.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<FileEntry> stat(String path) async {
    final data = _direct('stat', [path]);
    return FileEntry.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<TextContent> readText(
    String path, {
    int maxBytes = defaultReadLimit,
  }) async {
    final data = await _background('readText', [path, maxBytes]);
    return TextContent.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<FileEntry> writeText(String path, String content) async {
    final data = _direct('writeText', [path, content]);
    return FileEntry.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<Uint8List> readBytes(String path) async {
    final data = await _background('readBytes', [path]);
    return data as Uint8List;
  }

  Future<FileEntry> writeBytes(String path, Uint8List bytes) async {
    final data = _direct('writeBytes', [path, bytes]);
    return FileEntry.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<FileEntry> createDir(String path) async {
    final data = _direct('createDir', [path]);
    return FileEntry.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<FileEntry> createFile(String path) async {
    final data = _direct('createFile', [path]);
    return FileEntry.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<FileEntry> symlink(String target, String link) async {
    final data = _direct('symlink', [target, link]);
    return FileEntry.fromJson((data as Map).cast<String, dynamic>());
  }

  /// 图片 EXIF / 媒体信息。
  Future<Map<String, dynamic>> mediaInfo(String path) async {
    final data = await _background('mediaInfo', [path]);
    return (data as Map).cast<String, dynamic>();
  }

  /// 旋转图片（`left` / `right` / `180`），原地重写。
  Future<void> rotateImage(String path, String direction) async {
    await _background('imageRotate', [path, direction]);
  }

  /// 复制单个文件到指定路径。
  Future<FileEntry> copyFile(String source, String dest) async {
    final data = await _background('copyFile', [source, dest]);
    return FileEntry.fromJson((data as Map).cast<String, dynamic>());
  }

  /// 生成二维码 PNG 字节。
  Future<Uint8List?> qrPng(String text, {int scale = 6}) async {
    return await _background('qrPng', [text, scale]) as Uint8List?;
  }

  Future<FileEntry> rename(String path, String newName) async {
    final data = _direct('rename', [path, newName]);
    return FileEntry.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<DeleteResult> delete(List<String> paths, {bool toTrash = true}) async {
    final data = await _background('delete', [jsonEncode(paths), toTrash]);
    return DeleteResult.fromJson((data as Map).cast<String, dynamic>());
  }

  // -------------------------------------------------------------------------
  // 回收站
  // -------------------------------------------------------------------------

  Future<List<TrashEntry>> trashList() async {
    final data = _direct('trashList');
    return (data as List)
        .map((e) => TrashEntry.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<TrashRestoreResult> trashRestore(List<String> ids) async {
    final data = await _background('trashRestore', [jsonEncode(ids)]);
    return TrashRestoreResult.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<int> trashEmpty() async {
    final data = await _background('trashEmpty', const []);
    return (data as Map)['deleted'] as int? ?? 0;
  }

  Future<DeleteResult> trashRemove(List<String> ids) async {
    final data = await _background('trashRemove', [jsonEncode(ids)]);
    return DeleteResult.fromJson((data as Map).cast<String, dynamic>());
  }

  // -------------------------------------------------------------------------
  // 长任务进度
  // -------------------------------------------------------------------------

  int jobCreate() => _direct('jobCreate') as int;

  JobProgress jobStatus(int id) {
    final data = _direct('jobStatus', [id]);
    return JobProgress.fromJson((data as Map).cast<String, dynamic>());
  }

  void jobCancel(int id) => _direct('jobCancel', [id]);

  void jobCleanup(int id) => _direct('jobCleanup', [id]);

  // -------------------------------------------------------------------------
  // 归档（ZIP / TAR / TAR.GZ）
  // -------------------------------------------------------------------------

  /// 创建归档，格式由 `dest` 扩展名决定；`password` 仅对 ZIP 生效。
  Future<void> archiveCreate(
    List<String> sources,
    String dest, {
    String password = '',
    int jobId = 0,
  }) async {
    await _background('archiveCreate', [
      jsonEncode(sources),
      dest,
      jobId,
      password,
    ]);
  }

  /// 解压归档，`only` 非空时只解压该条目。
  Future<void> archiveExtract(
    String archivePath,
    String destDir, {
    String password = '',
    String? only,
    int jobId = 0,
  }) async {
    await _background('archiveExtract', [
      archivePath,
      destDir,
      jobId,
      password,
      only ?? '',
    ]);
  }

  Future<List<ArchiveEntry>> archiveList(String archivePath) async {
    final data = await _background('archiveList', [archivePath]);
    return (data as List)
        .map((e) => ArchiveEntry.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  // -------------------------------------------------------------------------
  // 缩略图
  // -------------------------------------------------------------------------

  /// 生成图片缩略图（JPEG 字节）；不支持的格式返回 null。
  Future<Uint8List?> thumbnail(String path, int maxPx) async {
    final data = await _background('thumbnail', [path, maxPx]);
    return data as Uint8List?;
  }

  // -------------------------------------------------------------------------
  // 存储分析
  // -------------------------------------------------------------------------

  Future<AnalyzeResult> analyze(String root, {int jobId = 0}) async {
    final data = await _background('analyze', [root, jobId]);
    return AnalyzeResult.fromJson((data as Map).cast<String, dynamic>());
  }

  /// 计算文件校验和（`sha256` 或 `md5`）。
  Future<({String algorithm, String hash, int size})> hash(
    String path, {
    String algorithm = 'sha256',
  }) async {
    final data = await _background('hash', [path, algorithm]);
    final map = (data as Map).cast<String, dynamic>();
    return (
      algorithm: map['algorithm']?.toString() ?? algorithm,
      hash: map['hash']?.toString() ?? '',
      size: (map['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// 按需统计文件夹大小与文件数（仅本地）。
  Future<({int size, int files, int dirs})> dirSize(String path) async {
    final data = await _background('dirSize', [path]);
    final map = (data as Map).cast<String, dynamic>();
    return (
      size: (map['size'] as num?)?.toInt() ?? 0,
      files: (map['files'] as num?)?.toInt() ?? 0,
      dirs: (map['dirs'] as num?)?.toInt() ?? 0,
    );
  }

  Future<TransferResult> copy(
    List<String> sources,
    String dest, {
    int jobId = 0,
  }) async {
    final data = await _background('copy', [jsonEncode(sources), dest, jobId]);
    return TransferResult.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<TransferResult> move(
    List<String> sources,
    String dest, {
    int jobId = 0,
  }) async {
    final data = await _background('move', [jsonEncode(sources), dest, jobId]);
    return TransferResult.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<SearchOutcome> search(
    String root,
    String query, {
    int limit = 500,
  }) async {
    final data = await _background('search', [root, query, limit]);
    return SearchOutcome.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<SearchOutcome> searchFiltered(
    String root,
    String query,
    SearchOptions options,
  ) async {
    final data = await _background('searchFiltered', [
      root,
      query,
      jsonEncode(options.toJson()),
    ]);
    return SearchOutcome.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<CleanupResult> cleanupScan(String root, {int limit = 2000}) async {
    final data = await _background('cleanupScan', [root, limit]);
    return CleanupResult.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<List<TrendSnapshot>> trendRecord(String root) async {
    final data = await _background('trendRecord', [root]);
    final map = (data as Map).cast<String, dynamic>();
    return (map['history'] as List? ?? const [])
        .map((e) => TrendSnapshot.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<TrendSnapshot>> trendHistory(String root) async {
    final data = await _background('trendHistory', [root]);
    return (data as List? ?? const [])
        .map((e) => TrendSnapshot.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<StorageRoot>> storageRoots() async {
    try {
      final hints = await PlatformService.storageVolumes();
      _direct('storageHints', [jsonEncode(hints)]);
    } catch (_) {
      // 非 Android 或原生层不可用时忽略，Rust 侧会自行探测。
    }
    final data = _direct('storageRoots');
    return (data as List)
        .map((e) => StorageRoot.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  // -------------------------------------------------------------------------
  // 远程连接（WebDAV / FTP / SMB）
  // -------------------------------------------------------------------------

  /// 设置配置目录与缓存目录，启动时调用一次。
  void configInit({required String configDir, required String cacheDir}) {
    _direct('configInit', [configDir, cacheDir]);
  }

  Future<List<ConnectionProfile>> profiles() async {
    final data = _direct('profileList');
    return (data as List)
        .map(
          (e) => ConnectionProfile.fromJson((e as Map).cast<String, dynamic>()),
        )
        .toList();
  }

  Future<ConnectionProfile> saveProfile(ConnectionProfile profile) async {
    final data = _direct('profileSave', [jsonEncode(profile.toJson())]);
    return ConnectionProfile.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<void> removeProfile(String id) async {
    _direct('profileRemove', [id]);
  }

  Future<void> testProfile(ConnectionProfile profile) async {
    await _background('profileTest', [jsonEncode(profile.toJson())]);
  }

  Future<void> disconnect(String id) async {
    _direct('netDisconnect', [id]);
  }

  /// 把远程文件下载到本地缓存，返回本地路径。
  Future<CacheFile> downloadToCache(String uri) async {
    final data = await _background('netDownload', [uri]);
    return CacheFile.fromJson((data as Map).cast<String, dynamic>());
  }

  // -------------------------------------------------------------------------
  // 本地文件服务器（HTTP/WebDAV + FTP）
  // -------------------------------------------------------------------------

  Future<ServerConfig> serverLoadConfig() async {
    final data = _direct('serverConfigLoad');
    return ServerConfig.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<ServerConfig> serverSaveConfig(ServerConfig config) async {
    final data = _direct('serverConfigSave', [jsonEncode(config.toJson())]);
    return ServerConfig.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<ServerStatus> serverStart(ServerConfig config) async {
    final data = await _background('serverStart', [
      jsonEncode(config.toJson()),
    ]);
    return ServerStatus.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<ServerStatus> serverStop() async {
    final data = await _background('serverStop', const []);
    return ServerStatus.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<ServerStatus> serverStatus() async {
    final data = _direct('serverStatus');
    return ServerStatus.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<ServerLog> serverLog() async {
    final data = _direct('serverLog');
    return ServerLog.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<void> serverLogClear() async {
    _direct('serverLogClear');
  }

  /// 导入外部拖入的文件（由 Android 原生移交的文件描述符）。
  Future<FileEntry> importFd({
    required int fd,
    required String destDir,
    required String name,
  }) async {
    final data = await _background('importFd', [fd, destDir, name]);
    return FileEntry.fromJson((data as Map).cast<String, dynamic>());
  }

  // -------------------------------------------------------------------------
  // 收藏夹
  // -------------------------------------------------------------------------

  Future<List<Favorite>> favorites() async {
    final data = _direct('favoriteList');
    return (data as List)
        .map((e) => Favorite.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<Favorite>> addFavorite(String name, String path) async {
    final data = _direct('favoriteAdd', [name, path]);
    return (data as List)
        .map((e) => Favorite.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<Favorite>> removeFavorite(String path) async {
    final data = _direct('favoriteRemove', [path]);
    return (data as List)
        .map((e) => Favorite.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  // -------------------------------------------------------------------------
  // 界面偏好（键值）
  // -------------------------------------------------------------------------

  Future<Map<String, String>> prefsAll() async {
    final data = _direct('prefAll');
    return (data as Map).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
  }

  Future<void> prefSet(String key, String value) async {
    _direct('prefSet', [key, value]);
  }

  Future<void> prefRemove(String key) async {
    _direct('prefRemove', [key]);
  }
}
