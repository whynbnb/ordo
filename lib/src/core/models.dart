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
  const DeleteResult({required this.deleted, required this.errors});

  final int deleted;
  final List<String> errors;

  factory DeleteResult.fromJson(Map<String, dynamic> json) {
    return DeleteResult(
      deleted: (json['deleted'] as num?)?.toInt() ?? 0,
      errors:
          (json['errors'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
    );
  }
}

class SearchOutcome {
  const SearchOutcome({
    required this.entries,
    required this.truncated,
    required this.scanned,
  });

  final List<FileEntry> entries;
  final bool truncated;
  final int scanned;

  factory SearchOutcome.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'] as List? ?? const [];
    return SearchOutcome(
      entries: raw
          .map((e) => FileEntry.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      truncated: json['truncated'] as bool? ?? false,
      scanned: (json['scanned'] as num?)?.toInt() ?? 0,
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

/// 本地文件服务器配置（HTTP/WebDAV + FTP）。
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
    required this.error,
  });

  final bool running;
  final int? httpPort;
  final int? ftpPort;
  final String root;
  final bool auth;
  final bool readOnly;
  final List<String> addresses;
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
      error: json['error'] as String?,
    );
  }

  String get host => addresses.isNotEmpty ? addresses.first : '127.0.0.1';

  String? get httpUrl => httpPort == null ? null : 'http://$host:$httpPort/';

  String? get ftpUrl => ftpPort == null ? null : 'ftp://$host:$ftpPort/';
}
