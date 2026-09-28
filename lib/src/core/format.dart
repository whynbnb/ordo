// 纯 Dart 的展示辅助函数（不依赖 Flutter）。

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  final text = index == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(value >= 100 ? 0 : 1);
  return '$text ${units[index]}';
}

String formatDate(int seconds) {
  if (seconds <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

String joinPath(String parent, String name) {
  if (parent.isEmpty) return name;
  if (parent.endsWith('/')) return '$parent$name';
  return '$parent/$name';
}

String parentOf(String path) {
  if (path.isEmpty || path == '/') return '/';
  var p = path;
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  final index = p.lastIndexOf('/');
  if (index <= 0) return '/';
  return p.substring(0, index);
}

String baseName(String path) {
  if (path.isEmpty) return '/';
  var p = path;
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  final index = p.lastIndexOf('/');
  return index < 0 ? p : p.substring(index + 1);
}

/// 把路径拆成面包屑，例如 `/storage/emulated/0/a` -> 各级的 (名称, 完整路径)。
List<(String, String)> breadcrumbs(String path) {
  final result = <(String, String)>[];
  if (path.isEmpty) return result;
  if (path == '/') return [('/', '/')];
  var current = '';
  for (final segment in path.split('/')) {
    if (segment.isEmpty) continue;
    current = '$current/$segment';
    result.add((segment, current));
  }
  return result;
}

/// 是否为远程 URI（WebDAV / FTP / SMB）。
bool isRemotePath(String path) =>
    path.startsWith('webdav://') ||
    path.startsWith('ftp://') ||
    path.startsWith('smb://');
