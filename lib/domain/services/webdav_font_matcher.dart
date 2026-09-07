import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/utils/url_utils.dart';
import '../../data/models/media_directory_entry.dart';

class WebDavFontFile {
  const WebDavFontFile({
    required this.name,
    required this.url,
    required this.size,
  });

  final String name;
  final String url;
  final int size;

  String get extension {
    final nameExtension = p.extension(name).toLowerCase();
    if (nameExtension.isNotEmpty) return nameExtension;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return '';
    return p.extension(uri.pathSegments.last).toLowerCase();
  }
}

class WebDavFontDirectory {
  const WebDavFontDirectory({
    required this.name,
    required this.requestPath,
    required this.entryKey,
    this.files = const [],
  });

  final String name;
  final String requestPath;
  final String entryKey;
  final List<WebDavFontFile> files;

  WebDavFontDirectory withFiles(List<WebDavFontFile> value) =>
      WebDavFontDirectory(
        name: name,
        requestPath: requestPath,
        entryKey: entryKey,
        files: List.unmodifiable(value),
      );
}

/// 识别媒体同级的字体目录，并只接受该目录的直属字体文件。
class WebDavFontMatcher {
  const WebDavFontMatcher();

  WebDavFontDirectory? findBestFor(
    MediaDirectoryEntry media,
    List<MediaDirectoryEntry> siblings, {
    required String baseUrl,
  }) {
    final matches = <({MediaDirectoryEntry entry, int score, String path})>[];
    for (final entry in siblings) {
      if (!entry.isDirectory || entry.isSelfEntry) continue;
      final score = _folderScores[_normalizeFolderName(entry.name)];
      if (score == null ||
          !_sameParent(baseUrl, media.entryKey, entry.entryKey)) {
        continue;
      }
      final requestPath = _requestPath(baseUrl, entry.entryKey);
      if (requestPath == null) continue;
      matches.add((entry: entry, score: score, path: requestPath));
    }
    if (matches.isEmpty) return null;
    matches.sort((left, right) {
      final byScore = right.score.compareTo(left.score);
      if (byScore != 0) return byScore;
      final byLength = left.entry.name.length.compareTo(
        right.entry.name.length,
      );
      if (byLength != 0) return byLength;
      return left.entry.name.toLowerCase().compareTo(
        right.entry.name.toLowerCase(),
      );
    });
    final match = matches.first;
    return WebDavFontDirectory(
      name: match.entry.name,
      requestPath: match.path,
      entryKey: match.entry.entryKey,
    );
  }

  WebDavFontDirectory withDirectFontFiles(
    WebDavFontDirectory directory,
    List<MediaDirectoryEntry> entries, {
    required String baseUrl,
  }) {
    final files = <WebDavFontFile>[];
    for (final entry in entries) {
      if (entry.isDirectory || entry.isSelfEntry) continue;
      if (!AppConstants.fontExtensions.contains(entry.extension)) continue;
      if (!_isDirectChild(baseUrl, directory.entryKey, entry.entryKey)) {
        continue;
      }
      final url = resolveHref(baseUrl, entry.entryKey);
      if (!isSameOrigin(baseUrl, url)) continue;
      files.add(WebDavFontFile(name: entry.name, url: url, size: entry.size));
    }
    return directory.withFiles(files);
  }

  static String _normalizeFolderName(
    String value,
  ) => value.trim().toLowerCase().replaceAll(
    RegExp(
      r'[\s._\-\u2010-\u2015\u2212\uff0d\u00b7\u2022\u2026()\[\]{}\uff08\uff09\u3010\u3011]+',
    ),
    '',
  );

  static String? _requestPath(String baseUrl, String entryKey) {
    final base = Uri.tryParse(baseUrl);
    final target = Uri.tryParse(resolveHref(baseUrl, entryKey));
    if (base == null ||
        target == null ||
        !isSameOrigin(baseUrl, target.toString())) {
      return null;
    }
    final baseSegments = _segments(base);
    final targetSegments = _segments(target);
    if (targetSegments.length <= baseSegments.length) return null;
    for (var index = 0; index < baseSegments.length; index++) {
      if (baseSegments[index] != targetSegments[index]) return null;
    }
    return targetSegments.sublist(baseSegments.length).join('/');
  }

  static bool _sameParent(
    String baseUrl,
    String mediaKey,
    String directoryKey,
  ) {
    final media = Uri.tryParse(resolveHref(baseUrl, mediaKey));
    final directory = Uri.tryParse(resolveHref(baseUrl, directoryKey));
    if (media == null || directory == null || !_sameOrigin(media, directory)) {
      return false;
    }
    final mediaSegments = _segments(media);
    final directorySegments = _segments(directory);
    if (mediaSegments.isEmpty ||
        mediaSegments.length != directorySegments.length) {
      return false;
    }
    return _listEquals(
      mediaSegments.sublist(0, mediaSegments.length - 1),
      directorySegments.sublist(0, directorySegments.length - 1),
    );
  }

  static bool _isDirectChild(
    String baseUrl,
    String directoryKey,
    String fileKey,
  ) {
    final directory = Uri.tryParse(resolveHref(baseUrl, directoryKey));
    final file = Uri.tryParse(resolveHref(baseUrl, fileKey));
    if (directory == null || file == null || !_sameOrigin(directory, file)) {
      return false;
    }
    final directorySegments = _segments(directory);
    final fileSegments = _segments(file);
    if (fileSegments.length != directorySegments.length + 1) return false;
    return _listEquals(
      directorySegments,
      fileSegments.sublist(0, directorySegments.length),
    );
  }

  static List<String> _segments(Uri uri) =>
      uri.pathSegments.where((segment) => segment.isNotEmpty).toList();

  static bool _sameOrigin(Uri left, Uri right) {
    if (!left.hasAuthority && !right.hasAuthority) return true;
    return left.hasAuthority &&
        right.hasAuthority &&
        left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
        left.host.toLowerCase() == right.host.toLowerCase() &&
        left.port == right.port;
  }

  static bool _listEquals(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static const Map<String, int> _folderScores = {
    'subtitlefont': 400,
    'subtitlefonts': 400,
    'subtitlesfont': 400,
    'subtitlesfonts': 400,
    'subfont': 400,
    'subfonts': 400,
    'assfont': 400,
    'assfonts': 400,
    '字幕字体': 400,
    '字幕字體': 400,
    '字幕字体文件': 390,
    '字幕字體文件': 390,
    '字幕字体包': 390,
    '字幕字體包': 390,
    '字幕字库': 390,
    '字幕字庫': 390,
    '字幕フォント': 400,
    '자막폰트': 400,
    'font': 300,
    'fonts': 300,
    '字体': 300,
    '字體': 300,
    'フォント': 300,
    '폰트': 300,
    'fontfiles': 250,
    'fontsfiles': 250,
    'fontpack': 250,
    'fontpacks': 250,
    'fontlibrary': 250,
    'fontslibrary': 250,
    '字体文件': 250,
    '字體文件': 250,
    '字体包': 250,
    '字體包': 250,
    '字库': 250,
    '字庫': 250,
    'fontbackup': 100,
    'fontsbackup': 100,
    '字体备份': 100,
    '字體備份': 100,
  };
}
