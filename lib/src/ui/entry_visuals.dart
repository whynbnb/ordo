import 'package:flutter/material.dart';

import '../core/file_types.dart';
import '../core/models.dart';

FileCategory categoryOfEntry(FileEntry entry) =>
    categoryOf(entry.extension, isDir: entry.isDir);

IconData iconForEntry(FileEntry entry) {
  return switch (categoryOfEntry(entry)) {
    FileCategory.folder => Icons.folder_rounded,
    FileCategory.image => Icons.image_rounded,
    FileCategory.video => Icons.movie_rounded,
    FileCategory.audio => Icons.audiotrack_rounded,
    FileCategory.document => Icons.description_rounded,
    FileCategory.text => Icons.article_rounded,
    FileCategory.archive => Icons.folder_zip_rounded,
    FileCategory.apk => Icons.android_rounded,
    FileCategory.other => Icons.insert_drive_file_rounded,
  };
}

Color colorForEntry(FileEntry entry, ColorScheme scheme) {
  return switch (categoryOfEntry(entry)) {
    FileCategory.folder => const Color(0xFFFFB300),
    FileCategory.image => const Color(0xFF26A69A),
    FileCategory.video => const Color(0xFFEF5350),
    FileCategory.audio => const Color(0xFFAB47BC),
    FileCategory.document => const Color(0xFF5C6BC0),
    FileCategory.text => const Color(0xFF42A5F5),
    FileCategory.archive => const Color(0xFF8D6E63),
    FileCategory.apk => const Color(0xFF66BB6A),
    FileCategory.other => scheme.outline,
  };
}
