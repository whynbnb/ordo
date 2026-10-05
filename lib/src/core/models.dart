// 与 Rust 核心交换的数据模型。字段名与 Rust 侧序列化结果保持一致。

class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.isSymlink,
    required this.hidden,
    required this.size,
    required this.modified,
    required this.created,
    required this.extension,
    required this.readable,
    required this.writable,
  });

  final String name;
  final String path;
  final bool isDir;
  final bool isSymlink;
  final bool hidden;
  final int size;
  final int modified;
  final int created;
  final String extension;
  final bool readable;
  final bool writable;

  factory FileEntry.fromJson(Map<String, dynamic> json) {
    return FileEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      isDir: json['is_dir'] as bool? ?? false,
      isSymlink: json['is_symlink'] as bool? ?? false,
      hidden: json['hidden'] as bool? ?? false,
      size: (json['size'] as num?)?.toInt() ?? 0,
      modified: (json['modified'] as num?)?.toInt() ?? 0,
      created: (json['created'] as num?)?.toInt() ?? 0,
      extension: json['extension'] as String? ?? '',
      readable: json['readable'] as bool? ?? false,
      writable: json['writable'] as bool? ?? false,
    );
  }

  DateTime? get modifiedAt => modified > 0
      ? DateTime.fromMillisecondsSinceEpoch(modified * 1000)
      : null;

  DateTime? get createdAt =>
      created > 0 ? DateTime.fromMillisecondsSinceEpoch(created * 1000) : null;

  FileEntry copyWith({String? name, String? path}) {
    return FileEntry(
      name: name ?? this.name,
      path: path ?? this.path,
      isDir: isDir,
      isSymlink: isSymlink,
      hidden: hidden,
      size: size,
      modified: modified,
      created: created,
      extension: extension,
      readable: readable,
      writable: writable,
    );
  }
}

class StorageRoot {
  const StorageRoot({
    required this.name,
    required this.path,
    required this.kind,
    required this.total,
    required this.free,
    required this.removable,
    required this.readable,
  });

  final String name;
  final String path;
  final String kind;
  final int total;
  final int free;
  final bool removable;
  final bool readable;

  factory StorageRoot.fromJson(Map<String, dynamic> json) {
    return StorageRoot(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      kind: json['kind'] as String? ?? 'internal',
      total: (json['total'] as num?)?.toInt() ?? 0,
      free: (json['free'] as num?)?.toInt() ?? 0,
      removable: json['removable'] as bool? ?? false,
      readable: json['readable'] as bool? ?? true,
    );
  }

  bool get isUsb => kind == 'usb';

  int get used => total - free;

  double get usedRatio => total > 0 ? used / total : 0;
}

class TextContent {
  const TextContent({
    required this.content,
    required this.truncated,
    required this.size,
  });

  final String content;
  final bool truncated;
  final int size;

  factory TextContent.fromJson(Map<String, dynamic> json) {
    return TextContent(
      content: json['content'] as String? ?? '',
      truncated: json['truncated'] as bool? ?? false,
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }
}

class TransferResult {
  const TransferResult({required this.done, required this.errors});

  final int done;
  final List<String> errors;

  factory TransferResult.fromJson(Map<String, dynamic> json) {
    return TransferResult(
      done: (json['done'] as num?)?.toInt() ?? 0,
      errors:
          (json['errors'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
    );
  }
}

class DeleteResult {
  const DeleteResult({
    required this.deleted,
    required this.trashed,
    required this.errors,
  });

  final int deleted;
  final int trashed;
  final List<String> errors;

  factory DeleteResult.fromJson(Map<String, dynamic> json) {
    return DeleteResult(
      deleted: (json['deleted'] as num?)?.toInt() ?? 0,
      trashed: (json['trashed'] as num?)?.toInt() ?? 0,
      errors:
          (json['errors'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
    );
  }
}

/// 回收站条目。
class TrashEntry {
  const TrashEntry({
    required this.id,
    required this.name,
    required this.originalPath,
    required this.deletedAt,
    required this.isDir,
    required this.size,
  });

  final String id;
  final String name;
  final String originalPath;
  final int deletedAt;
  final bool isDir;
  final int size;

  factory TrashEntry.fromJson(Map<String, dynamic> json) {
    return TrashEntry(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      originalPath: json['original_path'] as String? ?? '',
      deletedAt: (json['deleted_at'] as num?)?.toInt() ?? 0,
      isDir: json['is_dir'] as bool? ?? false,
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }

  DateTime? get deletedTime => deletedAt > 0
      ? DateTime.fromMillisecondsSinceEpoch(deletedAt * 1000)
      : null;
}

/// 回收站恢复结果。
class TrashRestoreResult {
  const TrashRestoreResult({required this.restored, required this.errors});

  final int restored;
  final List<String> errors;

  factory TrashRestoreResult.fromJson(Map<String, dynamic> json) {
    return TrashRestoreResult(
      restored: (json['restored'] as num?)?.toInt() ?? 0,
      errors:
          (json['errors'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
    );
  }
}

/// 存储分析：分类占用。
class CategoryStat {
  const CategoryStat({
    required this.category,
    required this.size,
    required this.count,
  });

  final String category;
  final int size;
  final int count;

  factory CategoryStat.fromJson(Map<String, dynamic> json) {
    return CategoryStat(
      category: json['category'] as String? ?? 'other',
      size: (json['size'] as num?)?.toInt() ?? 0,
      count: (json['count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 存储分析中的文件引用。
class AnalysisFile {
  const AnalysisFile({
    required this.path,
    required this.name,
    required this.size,
    required this.category,
  });

  final String path;
  final String name;
  final int size;
  final String category;

  factory AnalysisFile.fromJson(Map<String, dynamic> json) {
    return AnalysisFile(
      path: json['path'] as String? ?? '',
      name: json['name'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      category: json['category'] as String? ?? 'other',
    );
  }
}

/// 一组重复文件。
class DuplicateGroup {
  const DuplicateGroup({
    required this.size,
    required this.hash,
    required this.files,
  });

  final int size;
  final String hash;
  final List<AnalysisFile> files;

  factory DuplicateGroup.fromJson(Map<String, dynamic> json) {
    final raw = json['files'] as List? ?? const [];
    return DuplicateGroup(
      size: (json['size'] as num?)?.toInt() ?? 0,
      hash: json['hash'] as String? ?? '',
      files: raw
          .map((e) => AnalysisFile.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }

  int get reclaimable => size * (files.length - 1);
}

/// 存储分析结果。
class AnalyzeResult {
  const AnalyzeResult({
    required this.root,
    required this.totalSize,
    required this.fileCount,
    required this.dirCount,
    required this.categories,
    required this.largest,
    required this.duplicates,
  });

  final String root;
  final int totalSize;
  final int fileCount;
  final int dirCount;
  final List<CategoryStat> categories;
  final List<AnalysisFile> largest;
  final List<DuplicateGroup> duplicates;

  factory AnalyzeResult.fromJson(Map<String, dynamic> json) {
    List<T> parse<T>(String key, T Function(Map<String, dynamic>) build) {
      final raw = json[key] as List? ?? const [];
      return raw.map((e) => build((e as Map).cast<String, dynamic>())).toList();
    }

    return AnalyzeResult(
      root: json['root'] as String? ?? '',
      totalSize: (json['total_size'] as num?)?.toInt() ?? 0,
      fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
      dirCount: (json['dir_count'] as num?)?.toInt() ?? 0,
      categories: parse('categories', CategoryStat.fromJson),
      largest: parse('largest', AnalysisFile.fromJson),
      duplicates: parse('duplicates', DuplicateGroup.fromJson),
    );
  }
}

class SearchOutcome {
  const SearchOutcome({
    required this.entries,
    required this.truncated,
    required this.scanned,
    this.content = false,
  });

  final List<FileEntry> entries;
  final bool truncated;
  final int scanned;
  final bool content;

  factory SearchOutcome.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'] as List? ?? const [];
    return SearchOutcome(
      entries: raw
          .map((e) => FileEntry.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      truncated: json['truncated'] as bool? ?? false,
      scanned: (json['scanned'] as num?)?.toInt() ?? 0,
      content: json['content'] as bool? ?? false,
    );
  }
}

/// 搜索过滤条件。
class SearchOptions {
  const SearchOptions({
    this.limit = 500,
    this.minSize = 0,
    this.maxSize = 0,
    this.after = 0,
    this.before = 0,
    this.extensions = const [],
    this.kind = 'any',
    this.content = false,
    this.contentMax = 0,
    this.skipHidden = false,
  });

  final int limit;
  final int minSize;
  final int maxSize;
  final int after;
  final int before;
  final List<String> extensions;
  final String kind;
  final bool content;
  final int contentMax;
  final bool skipHidden;

  static const SearchOptions none = SearchOptions();

  /// 除分页外是否有过滤条件。
  bool get hasFilters =>
      minSize > 0 ||
      maxSize > 0 ||
      after > 0 ||
      before > 0 ||
      extensions.isNotEmpty ||
      kind != 'any' ||
      content ||
      skipHidden;

  factory SearchOptions.fromJson(Map<String, dynamic> json) {
    return SearchOptions(
      limit: (json['limit'] as num?)?.toInt() ?? 500,
      minSize: (json['min_size'] as num?)?.toInt() ?? 0,
      maxSize: (json['max_size'] as num?)?.toInt() ?? 0,
      after: (json['after'] as num?)?.toInt() ?? 0,
      before: (json['before'] as num?)?.toInt() ?? 0,
      extensions:
          (json['extensions'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      kind: json['kind'] as String? ?? 'any',
      content: json['content'] as bool? ?? false,
      contentMax: (json['content_max'] as num?)?.toInt() ?? 0,
      skipHidden: json['skip_hidden'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'limit': limit,
    'min_size': minSize,
    'max_size': maxSize,
    'after': after,
    'before': before,
    'extensions': extensions,
    'kind': kind,
    'content': content,
    'content_max': contentMax,
    'skip_hidden': skipHidden,
  };

  SearchOptions copyWith({
    int? limit,
    int? minSize,
    int? maxSize,
    int? after,
    int? before,
    List<String>? extensions,
    String? kind,
    bool? content,
    int? contentMax,
    bool? skipHidden,
  }) {
    return SearchOptions(
      limit: limit ?? this.limit,
      minSize: minSize ?? this.minSize,
      maxSize: maxSize ?? this.maxSize,
      after: after ?? this.after,
      before: before ?? this.before,
      extensions: extensions ?? this.extensions,
      kind: kind ?? this.kind,
      content: content ?? this.content,
      contentMax: contentMax ?? this.contentMax,
      skipHidden: skipHidden ?? this.skipHidden,
    );
  }
}

/// 一条远程连接配置（WebDAV / FTP / SMB）。
class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.kind,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.basePath,
    required this.share,
    required this.domain,
    required this.secure,
    required this.insecureTls,
  });

  final String id;
  final String name;
  final String kind;
  final String host;
  final int port;
  final String username;
  final String password;
  final String basePath;
  final String share;
  final String domain;
  final bool secure;
  final bool insecureTls;

  static const ConnectionProfile empty = ConnectionProfile(
    id: '',
    name: '',
    kind: 'webdav',
    host: '',
    port: 0,
    username: '',
    password: '',
    basePath: '',
    share: '',
    domain: '',
    secure: false,
    insecureTls: false,
  );

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) {
    return ConnectionProfile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      kind: json['kind'] as String? ?? 'webdav',
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      basePath: json['base_path'] as String? ?? '',
      share: json['share'] as String? ?? '',
      domain: json['domain'] as String? ?? '',
      secure: json['secure'] as bool? ?? false,
      insecureTls: json['insecure_tls'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'base_path': basePath,
    'share': share,
    'domain': domain,
    'secure': secure,
    'insecure_tls': insecureTls,
  };

  String get scheme => kind;

  String get rootUri => '$kind://$id/';

  ConnectionProfile copyWith({
    String? id,
    String? name,
    String? kind,
    String? host,
    int? port,
    String? username,
    String? password,
    String? basePath,
    String? share,
    String? domain,
    bool? secure,
    bool? insecureTls,
  }) {
    return ConnectionProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      basePath: basePath ?? this.basePath,
      share: share ?? this.share,
      domain: domain ?? this.domain,
      secure: secure ?? this.secure,
      insecureTls: insecureTls ?? this.insecureTls,
    );
  }
}

/// `ordo_net_download` 的结果。
class CacheFile {
  const CacheFile({required this.path, required this.name});

  final String path;
  final String name;

  factory CacheFile.fromJson(Map<String, dynamic> json) {
    return CacheFile(
      path: json['path'] as String? ?? '',
      name: json['name'] as String? ?? '',
    );
  }
}

/// 压缩包条目。
class ArchiveEntry {
  const ArchiveEntry({
    required this.name,
    required this.size,
    required this.compressed,
    required this.isDir,
    required this.encrypted,
  });

  final String name;
  final int size;
  final int compressed;
  final bool isDir;
  final bool encrypted;

  factory ArchiveEntry.fromJson(Map<String, dynamic> json) {
    return ArchiveEntry(
      name: json['name'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      compressed: (json['compressed'] as num?)?.toInt() ?? 0,
      isDir: json['is_dir'] as bool? ?? false,
      encrypted: json['encrypted'] as bool? ?? false,
    );
  }
}

/// 长任务（复制 / 移动 / 压缩 / 分析）的进度。
class JobProgress {
  const JobProgress({
    required this.progress,
    required this.total,
    required this.cancelled,
    required this.done,
  });

  final int progress;
  final int total;
  final bool cancelled;
  final bool done;

  static const JobProgress idle = JobProgress(
    progress: 0,
    total: 0,
    cancelled: false,
    done: false,
  );

  factory JobProgress.fromJson(Map<String, dynamic> json) {
    return JobProgress(
      progress: (json['progress'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      cancelled: json['cancelled'] as bool? ?? false,
      done: json['done'] as bool? ?? false,
    );
  }

  /// 0..1；总量未知时为 null（界面显示不确定进度）。
  double? get fraction => total > 0 ? (progress / total).clamp(0.0, 1.0) : null;
}

/// 收藏夹条目。
class Favorite {
  const Favorite({required this.name, required this.path});

  final String name;
  final String path;

  factory Favorite.fromJson(Map<String, dynamic> json) {
    return Favorite(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'name': name, 'path': path};
}

/// 本地文件服务器配置（HTTP/WebDAV + FTP）。
class ServerUser {
  const ServerUser({
    required this.username,
    required this.password,
    required this.path,
    required this.readOnly,
  });

  final String username;
  final String password;
  final String path;
  final bool readOnly;

  factory ServerUser.fromJson(Map<String, dynamic> json) {
    return ServerUser(
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      path: json['path'] as String? ?? '',
      readOnly: json['read_only'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'username': username,
    'password': password,
    'path': path,
    'read_only': readOnly,
  };

  ServerUser copyWith({
    String? username,
    String? password,
    String? path,
    bool? readOnly,
  }) {
    return ServerUser(
      username: username ?? this.username,
      password: password ?? this.password,
      path: path ?? this.path,
      readOnly: readOnly ?? this.readOnly,
    );
  }
}

class ServerConfig {
  const ServerConfig({
    required this.root,
    required this.http,
    required this.httpPort,
    required this.ftp,
    required this.ftpPort,
    required this.auth,
    required this.username,
    required this.password,
    required this.readOnly,
    this.users = const [],
  });

  final String root;
  final bool http;
  final int httpPort;
  final bool ftp;
  final int ftpPort;
  final bool auth;
  final String username;
  final String password;
  final bool readOnly;
  final List<ServerUser> users;

  static const ServerConfig empty = ServerConfig(
    root: '',
    http: true,
    httpPort: 8080,
    ftp: false,
    ftpPort: 2121,
    auth: false,
    username: '',
    password: '',
    readOnly: false,
  );

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      root: json['root'] as String? ?? '',
      http: json['http'] as bool? ?? false,
      httpPort: (json['http_port'] as num?)?.toInt() ?? 0,
      ftp: json['ftp'] as bool? ?? false,
      ftpPort: (json['ftp_port'] as num?)?.toInt() ?? 0,
      auth: json['auth'] as bool? ?? false,
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      readOnly: json['read_only'] as bool? ?? false,
      users:
          (json['users'] as List?)
              ?.map((e) => ServerUser.fromJson((e as Map).cast<String, dynamic>()))
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'root': root,
    'http': http,
    'http_port': httpPort,
    'ftp': ftp,
    'ftp_port': ftpPort,
    'auth': auth,
    'username': username,
    'password': password,
    'read_only': readOnly,
    'users': [for (final user in users) user.toJson()],
  };

  ServerConfig copyWith({
    String? root,
    bool? http,
    int? httpPort,
    bool? ftp,
    int? ftpPort,
    bool? auth,
    String? username,
    String? password,
    bool? readOnly,
    List<ServerUser>? users,
  }) {
    return ServerConfig(
      root: root ?? this.root,
      http: http ?? this.http,
      httpPort: httpPort ?? this.httpPort,
      ftp: ftp ?? this.ftp,
      ftpPort: ftpPort ?? this.ftpPort,
      auth: auth ?? this.auth,
      username: username ?? this.username,
      password: password ?? this.password,
      readOnly: readOnly ?? this.readOnly,
      users: users ?? this.users,
    );
  }
}

/// 文件服务器运行状态。
class ServerStatus {
  const ServerStatus({
    required this.running,
    required this.httpPort,
    required this.ftpPort,
    required this.root,
    required this.auth,
    required this.readOnly,
    required this.addresses,
    required this.users,
    required this.error,
  });

  final bool running;
  final int? httpPort;
  final int? ftpPort;
  final String root;
  final bool auth;
  final bool readOnly;
  final List<String> addresses;
  final List<String> users;
  final String? error;

  factory ServerStatus.fromJson(Map<String, dynamic> json) {
    return ServerStatus(
      running: json['running'] as bool? ?? false,
      httpPort: (json['http_port'] as num?)?.toInt(),
      ftpPort: (json['ftp_port'] as num?)?.toInt(),
      root: json['root'] as String? ?? '',
      auth: json['auth'] as bool? ?? false,
      readOnly: json['read_only'] as bool? ?? false,
      addresses:
          (json['addresses'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      users: (json['users'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      error: json['error'] as String?,
    );
  }

  String get host => addresses.isNotEmpty ? addresses.first : '127.0.0.1';

  String? get httpUrl => httpPort == null ? null : 'http://$host:$httpPort/';

  String? get ftpUrl => ftpPort == null ? null : 'ftp://$host:$ftpPort/';
}

/// 一条服务器访问记录。
class ServerAccessEntry {
  const ServerAccessEntry({
    required this.time,
    required this.protocol,
    required this.client,
    required this.action,
    required this.path,
    required this.status,
  });

  final int time;
  final String protocol;
  final String client;
  final String action;
  final String path;
  final int status;

  factory ServerAccessEntry.fromJson(Map<String, dynamic> json) {
    return ServerAccessEntry(
      time: (json['time'] as num?)?.toInt() ?? 0,
      protocol: json['protocol'] as String? ?? '',
      client: json['client'] as String? ?? '',
      action: json['action'] as String? ?? '',
      path: json['path'] as String? ?? '',
      status: (json['status'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 最近活跃的客户端。
class ServerClientEntry {
  const ServerClientEntry({
    required this.address,
    required this.protocol,
    required this.lastSeen,
    required this.requests,
  });

  final String address;
  final String protocol;
  final int lastSeen;
  final int requests;

  factory ServerClientEntry.fromJson(Map<String, dynamic> json) {
    return ServerClientEntry(
      address: json['address'] as String? ?? '',
      protocol: json['protocol'] as String? ?? '',
      lastSeen: (json['last_seen'] as num?)?.toInt() ?? 0,
      requests: (json['requests'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 服务器访问日志快照。
class ServerLog {
  const ServerLog({
    required this.entries,
    required this.clients,
    required this.revision,
  });

  final List<ServerAccessEntry> entries;
  final List<ServerClientEntry> clients;
  final int revision;

  static const ServerLog empty = ServerLog(
    entries: [],
    clients: [],
    revision: 0,
  );

  factory ServerLog.fromJson(Map<String, dynamic> json) {
    return ServerLog(
      entries:
          (json['entries'] as List?)
              ?.map(
                (e) =>
                    ServerAccessEntry.fromJson((e as Map).cast<String, dynamic>()),
              )
              .toList() ??
          const [],
      clients:
          (json['clients'] as List?)
              ?.map(
                (e) =>
                    ServerClientEntry.fromJson((e as Map).cast<String, dynamic>()),
              )
              .toList() ??
          const [],
      revision: (json['revision'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 智能清理扫描结果。
class CleanupResult {
  const CleanupResult({
    required this.emptyFiles,
    required this.emptyDirs,
    required this.tempFiles,
    required this.reclaimable,
    required this.scanned,
    required this.truncated,
  });

  final List<FileEntry> emptyFiles;
  final List<FileEntry> emptyDirs;
  final List<FileEntry> tempFiles;
  final int reclaimable;
  final int scanned;
  final bool truncated;

  int get total => emptyFiles.length + emptyDirs.length + tempFiles.length;

  static const CleanupResult empty = CleanupResult(
    emptyFiles: [],
    emptyDirs: [],
    tempFiles: [],
    reclaimable: 0,
    scanned: 0,
    truncated: false,
  );

  factory CleanupResult.fromJson(Map<String, dynamic> json) {
    List<FileEntry> parse(String key) {
      final raw = json[key] as List? ?? const [];
      return raw
          .map((e) => FileEntry.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    }

    return CleanupResult(
      emptyFiles: parse('empty_files'),
      emptyDirs: parse('empty_dirs'),
      tempFiles: parse('temp_files'),
      reclaimable: (json['reclaimable'] as num?)?.toInt() ?? 0,
      scanned: (json['scanned'] as num?)?.toInt() ?? 0,
      truncated: json['truncated'] as bool? ?? false,
    );
  }
}

/// 一次存储用量快照。
class TrendSnapshot {
  const TrendSnapshot({
    required this.time,
    required this.bytes,
    required this.files,
  });

  final int time;
  final int bytes;
  final int files;

  factory TrendSnapshot.fromJson(Map<String, dynamic> json) {
    return TrendSnapshot(
      time: (json['time'] as num?)?.toInt() ?? 0,
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      files: (json['files'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 隐私空间迁移 / 还原 / 删除结果。
class VaultResult {
  const VaultResult({required this.count, required this.errors});

  final int count;
  final List<String> errors;

  factory VaultResult.fromJson(Map<String, dynamic> json) {
    final count =
        (json['moved'] as num?)?.toInt() ??
        (json['restored'] as num?)?.toInt() ??
        (json['deleted'] as num?)?.toInt() ??
        0;
    return VaultResult(
      count: count,
      errors:
          (json['errors'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
    );
  }
}

/// 崩溃 / 错误日志。
class CrashLog {
  const CrashLog({required this.path, required this.text, required this.lines});

  final String path;
  final String text;
  final int lines;

  static const CrashLog empty = CrashLog(path: '', text: '', lines: 0);

  bool get isEmpty => text.isEmpty;

  factory CrashLog.fromJson(Map<String, dynamic> json) {
    return CrashLog(
      path: json['path'] as String? ?? '',
      text: json['text'] as String? ?? '',
      lines: (json['lines'] as num?)?.toInt() ?? 0,
    );
  }
}
