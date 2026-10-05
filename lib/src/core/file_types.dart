enum FileCategory {
  folder,
  image,
  video,
  audio,
  document,
  text,
  archive,
  apk,
  other,
}

const _image = {
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'bmp',
  'heic',
  'heif',
  'avif',
  'svg',
};
const _video = {'mp4', 'mkv', 'avi', 'mov', 'webm', '3gp', 'flv', 'wmv', 'm4v'};
const _audio = {
  'mp3',
  'wav',
  'flac',
  'aac',
  'ogg',
  'm4a',
  'wma',
  'opus',
  'amr',
};
const _document = {
  'pdf',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'odt',
  'ods',
};
const _text = {
  'txt',
  'md',
  'markdown',
  'json',
  'xml',
  'yaml',
  'yml',
  'csv',
  'log',
  'ini',
  'conf',
  'toml',
  'dart',
  'js',
  'ts',
  'jsx',
  'tsx',
  'py',
  'rs',
  'java',
  'kt',
  'kts',
  'c',
  'h',
  'cpp',
  'hpp',
  'cc',
  'cs',
  'go',
  'rb',
  'php',
  'swift',
  'sh',
  'bash',
  'zsh',
  'html',
  'htm',
  'css',
  'scss',
  'sql',
  'gradle',
  'properties',
};
const _archive = {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'tgz', 'iso'};

FileCategory categoryOf(String extension, {bool isDir = false}) {
  if (isDir) return FileCategory.folder;
  final ext = extension.toLowerCase();
  if (ext == 'apk' || ext == 'apks' || ext == 'xapk') return FileCategory.apk;
  if (_image.contains(ext)) return FileCategory.image;
  if (_video.contains(ext)) return FileCategory.video;
  if (_audio.contains(ext)) return FileCategory.audio;
  if (_document.contains(ext)) return FileCategory.document;
  if (_archive.contains(ext)) return FileCategory.archive;
  if (_text.contains(ext)) return FileCategory.text;
  return FileCategory.other;
}

/// 能否在应用内以纯文本方式查看。
bool isTextExtension(String extension) =>
    _text.contains(extension.toLowerCase());

/// 能否在应用内预览图片。
bool isImageExtension(String extension) =>
    _image.contains(extension.toLowerCase());

/// 是否为视频（用于生成缩略图）。
bool isVideoExtension(String extension) =>
    _video.contains(extension.toLowerCase());

/// 是否为音频。
bool isAudioExtension(String extension) =>
    _audio.contains(extension.toLowerCase());

/// 能否在应用内预览（图片 / 音频 / 文本）。视频不做应用内预览。
bool isPreviewableExtension(String extension) {
  final ext = extension.toLowerCase();
  return _image.contains(ext) || _audio.contains(ext) || _text.contains(ext);
}

/// 「默认打开方式」使用的分类键。
String openWithCategory(String extension) {
  final ext = extension.toLowerCase();
  if (ext == 'apk' || ext == 'apks' || ext == 'xapk') return 'apk';
  if (_image.contains(ext)) return 'image';
  if (_audio.contains(ext)) return 'audio';
  if (_video.contains(ext)) return 'video';
  if (_text.contains(ext)) return 'text';
  if (ext == 'pdf') return 'pdf';
  return 'other';
}

/// 是否为应用支持的归档格式（ZIP / TAR / TAR.GZ）。
bool isSupportedArchive(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.zip') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.tar.gz') ||
      lower.endsWith('.tgz');
}

/// 归档格式标签；非支持格式返回 null。
String? archiveFormatLabel(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.zip')) return 'ZIP';
  if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) return 'TAR.GZ';
  if (lower.endsWith('.tar')) return 'TAR';
  return null;
}

const Map<String, String> _mimeByExtension = {
  'txt': 'text/plain',
  'md': 'text/markdown',
  'log': 'text/plain',
  'json': 'application/json',
  'xml': 'application/xml',
  'html': 'text/html',
  'htm': 'text/html',
  'css': 'text/css',
  'csv': 'text/csv',
  'pdf': 'application/pdf',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'heic': 'image/heic',
  'svg': 'image/svg+xml',
  'mp4': 'video/mp4',
  'mkv': 'video/x-matroska',
  'avi': 'video/x-msvideo',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  '3gp': 'video/3gpp',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'flac': 'audio/flac',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
  'm4a': 'audio/mp4',
  'apk': 'application/vnd.android.package-archive',
  'zip': 'application/zip',
  'rar': 'application/vnd.rar',
  '7z': 'application/x-7z-compressed',
  'tar': 'application/x-tar',
  'gz': 'application/gzip',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
};

String mimeOfExtension(String extension, {bool isDir = false}) {
  if (isDir) return 'resource/folder';
  return _mimeByExtension[extension.toLowerCase()] ?? '*/*';
}
