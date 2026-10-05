import 'format.dart';
import '../i18n/i18n.dart';

/// 路径中的一段（用于面包屑导航）。
class PathCrumb {
  const PathCrumb(this.label, this.path);

  final String label;
  final String path;
}

/// 把本地路径或远程 URI 拆成可点击的面包屑。
List<PathCrumb> breadcrumbsFor(String path) {
  if (isRemotePath(path)) {
    final separator = path.indexOf('://');
    if (separator < 0) return const [];
    final scheme = path.substring(0, separator);
    final rest = path.substring(separator + 3);
    final slash = rest.indexOf('/');
    final id = slash < 0 ? rest : rest.substring(0, slash);
    final inner = slash < 0 ? '/' : rest.substring(slash);
    final base = '$scheme://$id';

    final crumbs = <PathCrumb>[PathCrumb(scheme.toUpperCase(), '$base/')];
    var acc = '';
    for (final segment in inner.split('/')) {
      if (segment.isEmpty) continue;
      acc = '$acc/$segment';
      crumbs.add(PathCrumb(segment, '$base$acc'));
    }
    return crumbs;
  }

  const internal = '/storage/emulated/0';
  final crumbs = <PathCrumb>[];
  if (path == internal || path.startsWith('$internal/')) {
    crumbs.add(PathCrumb(tr('内部存储'), internal));
    var acc = internal;
    for (final segment in path.substring(internal.length).split('/')) {
      if (segment.isEmpty) continue;
      acc = '$acc/$segment';
      crumbs.add(PathCrumb(segment, acc));
    }
    return crumbs;
  }

  var acc = '';
  for (final segment in path.split('/')) {
    if (segment.isEmpty) continue;
    acc = '$acc/$segment';
    crumbs.add(PathCrumb(segment, acc));
  }
  return crumbs;
}
