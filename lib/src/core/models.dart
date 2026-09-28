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
  });

  final String name;
  final String path;
  final String kind;
  final int total;
  final int free;
  final bool removable;

  factory StorageRoot.fromJson(Map<String, dynamic> json) {
    return StorageRoot(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      kind: json['kind'] as String? ?? 'internal',
      total: (json['total'] as num?)?.toInt() ?? 0,
      free: (json['free'] as num?)?.toInt() ?? 0,
      removable: json['removable'] as bool? ?? false,
    );
  }

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
