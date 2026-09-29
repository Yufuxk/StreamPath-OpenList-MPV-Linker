import 'dart:async';
import 'dart:io';

import '../../core/errors/app_exception.dart';
import '../../core/utils/file_sort.dart';
import '../../core/utils/url_utils.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';
import '../../data/models/special_playlist_mode.dart';
import '../repositories/media_directory_source.dart';
import 'webdav_media_source_adapter.dart';

class SpecialVideoItem {
  const SpecialVideoItem(this.entry, this.siblings, this.parentPath, this.path);

  final MediaDirectoryEntry entry;
  final List<MediaDirectoryEntry> siblings;
  final String parentPath;
  final String path;
}

class SpecialVideoScanResult {
  const SpecialVideoScanResult(this.items, this.incomplete);

  final List<SpecialVideoItem> items;
  final bool incomplete;
}

class SpecialVideoPlaylistCollector {
  const SpecialVideoPlaylistCollector();

  static const maxDepth = 5;
  static const maxDirectories = 64;
  static const maxVideos = 1000;
  static const maxConcurrent = 4;
  static const scanTimeout = Duration(seconds: 20);

  static final _extraEnglish = RegExp(
    r'(^|[^a-z])(?:extras?|specials?|bonus(?:[ ._-]*features?)?|ovas?|oavs?|oads?|onas?|sps?|ncop|nced|creditless|pvs?|cms?|promos?|trailers?|teasers?|behind[ ._-]*the[ ._-]*scenes|making[ ._-]*of|featurettes?|interviews?|deleted[ ._-]*scenes|shorts?|menus?)(?:\d+)?($|[^a-z])',
  );
  static final _seasonZero = RegExp(
    r'(^|[^a-z])(?:season[ ._-]*0+|s0+)(?=$|[^a-z0-9])',
  );
  static final _ovaEnglish = RegExp(
    r'(^|[^a-z])(?:ovas?|oavs?|oads?)(?:\d+)?($|[^a-z])',
  );
  static const _extraCjk = [
    '特典',
    '映像特典',
    '番外',
    '特别篇',
    '特別篇',
    '番外編',
    '特別編',
    '花絮',
    '幕后',
    '幕後',
    '预告',
    '預告',
    'ノンクレジット',
  ];
  static const _ovaCjk = ['番外', '番外篇', '番外編'];

  static String _normalized(String value) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      buffer.writeCharCode(
        rune >= 0xff01 && rune <= 0xff5e ? rune - 0xfee0 : rune,
      );
    }
    return buffer.toString().toLowerCase();
  }

  static bool isSpecialName(String name) {
    final value = _normalized(name);
    return _extraEnglish.hasMatch(value) ||
        _seasonZero.hasMatch(value) ||
        _extraCjk.any(value.contains) ||
        value.contains('无字幕op') ||
        value.contains('無字幕op') ||
        value.contains('无字幕ed') ||
        value.contains('無字幕ed');
  }

  static bool isOvaName(String name) {
    final value = _normalized(name);
    return _ovaEnglish.hasMatch(value) || _ovaCjk.any(value.contains);
  }

  static bool _excludedDirectory(String name) {
    final value = _normalized(name).trim();
    return value == 'bdmv' || value == 'certificate';
  }

  /// 只接受来源报告的直属条目，返回来源根目录下的相对路径。
  static String? directChildPath(
    MediaDirectorySource source,
    String parentPath,
    MediaDirectoryEntry entry,
  ) {
    if (entry.isSelfEntry) return null;
    if (source.descriptor.kind == MediaSourceKind.local) {
      final parent = parentPath.isEmpty ? '' : '$parentPath/';
      final path = entry.relativePath.replaceAll('\\', '/');
      if (!path.startsWith(parent)) return null;
      final child = path.substring(parent.length);
      if (child.isEmpty ||
          child == '.' ||
          child == '..' ||
          child.contains('/')) {
        return null;
      }
      return path;
    }
    final adapter = source as WebDavMediaSourceAdapter;
    final base = Uri.tryParse(adapter.service.baseUrl);
    final parent = Uri.tryParse(adapter.service.fullUrl(parentPath));
    final child = Uri.tryParse(
      resolveHref(adapter.service.baseUrl, entry.entryKey),
    );
    if (base == null ||
        parent == null ||
        child == null ||
        !isSameOrigin(parent.toString(), child.toString()) ||
        !isSameOrigin(base.toString(), child.toString())) {
      return null;
    }
    final baseParts = base.pathSegments
        .where((part) => part.isNotEmpty)
        .toList();
    final parentParts = parent.pathSegments
        .where((part) => part.isNotEmpty)
        .toList();
    final childParts = child.pathSegments
        .where((part) => part.isNotEmpty)
        .toList();
    if (childParts.length != parentParts.length + 1 ||
        childParts.length <= baseParts.length) {
      return null;
    }
    for (var i = 0; i < parentParts.length; i++) {
      if (parentParts[i] != childParts[i]) return null;
    }
    for (var i = 0; i < baseParts.length; i++) {
      if (baseParts[i] != childParts[i]) return null;
    }
    if (childParts.any(
      (part) =>
          part.isEmpty ||
          part == '.' ||
          part == '..' ||
          part.contains('/') ||
          part.contains('\\'),
    )) {
      return null;
    }
    return childParts.skip(baseParts.length).join('/');
  }

  Future<SpecialVideoScanResult> collect({
    required MediaDirectorySource source,
    required String rootPath,
    required List<MediaDirectoryEntry> rootEntries,
    required SpecialPlaylistMode mode,
    bool scanChildFolders = true,
    bool scanSiblingFolders = false,
  }) async {
    if (mode == SpecialPlaylistMode.off ||
        (!scanChildFolders && !scanSiblingFolders) ||
        rootPath.split('/').any((part) => part.toLowerCase() == 'bdmv')) {
      return const SpecialVideoScanResult([], false);
    }
    final queue = <_DirectoryJob>[];
    void enqueueSpecialFolders(
      String parentPath,
      List<MediaDirectoryEntry> entries,
    ) {
      for (final entry in entries) {
        if (!entry.isDirectory ||
            _excludedDirectory(entry.name) ||
            !isSpecialName(entry.name)) {
          continue;
        }
        final path = directChildPath(source, parentPath, entry);
        if (path != null && path != rootPath) {
          queue.add(_DirectoryJob(entry, path, 1, isOvaName(entry.name)));
        }
      }
    }

    if (scanChildFolders) enqueueSpecialFolders(rootPath, rootEntries);
    final visited = <String>{};
    final items = <SpecialVideoItem>[];
    final deadline = DateTime.now().add(scanTimeout);
    var scanned = 0;
    var incomplete = false;
    if (scanSiblingFolders &&
        rootPath.isNotEmpty &&
        !isSpecialName(rootPath.split('/').last)) {
      final separator = rootPath.lastIndexOf('/');
      final parentPath = separator < 0 ? '' : rootPath.substring(0, separator);
      scanned++;
      try {
        final siblings = await source
            .fetchDirectory(parentPath)
            .timeout(deadline.difference(DateTime.now()));
        enqueueSpecialFolders(parentPath, siblings);
      } on AppException {
        incomplete = true;
      } on FileSystemException {
        incomplete = true;
      } on TimeoutException {
        incomplete = true;
      }
    }
    while (queue.isNotEmpty && items.length < maxVideos) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero || scanned >= maxDirectories) {
        incomplete = true;
        break;
      }
      final jobs = <_DirectoryJob>[];
      while (queue.isNotEmpty &&
          jobs.length < maxConcurrent &&
          scanned + jobs.length < maxDirectories) {
        final job = queue.removeAt(0);
        if (!visited.add(job.path)) continue;
        try {
          final target = await source.resolve(job.entry);
          if (target is LocalMediaOpenTarget) {
            final canonical = await Directory(
              target.path,
            ).resolveSymbolicLinks();
            if (!visited.add('local:$canonical')) continue;
          }
        } on AppException {
          incomplete = true;
          continue;
        } on FileSystemException {
          incomplete = true;
          continue;
        }
        jobs.add(job);
      }
      scanned += jobs.length;
      final results = await Future.wait(
        jobs.map((job) async {
          try {
            return await source.fetchDirectory(job.path).timeout(remaining);
          } on AppException {
            return null;
          } on FileSystemException {
            return null;
          } on TimeoutException {
            return null;
          }
        }),
      );
      for (var i = 0; i < jobs.length; i++) {
        final job = jobs[i];
        final siblings = results[i];
        if (siblings == null) {
          incomplete = true;
          continue;
        }
        for (final entry in siblings) {
          final path = directChildPath(source, job.path, entry);
          if (path == null) continue;
          if (entry.isDirectory) {
            if (_excludedDirectory(entry.name)) continue;
            if (job.depth < maxDepth) {
              queue.add(
                _DirectoryJob(
                  entry,
                  path,
                  job.depth + 1,
                  job.ovaAncestor || isOvaName(entry.name),
                ),
              );
            } else {
              incomplete = true;
            }
          } else if (entry.isVideo &&
              (mode == SpecialPlaylistMode.all ||
                  job.ovaAncestor ||
                  isOvaName(entry.name))) {
            if (items.length == maxVideos) {
              incomplete = true;
              break;
            }
            items.add(SpecialVideoItem(entry, siblings, job.path, path));
          }
        }
      }
    }
    if (queue.isNotEmpty) incomplete = true;
    items.sort((left, right) {
      final name = naturalCompare(left.entry.name, right.entry.name);
      return name != 0 ? name : left.path.compareTo(right.path);
    });
    return SpecialVideoScanResult(items, incomplete);
  }
}

class _DirectoryJob {
  const _DirectoryJob(this.entry, this.path, this.depth, this.ovaAncestor);
  final MediaDirectoryEntry entry;
  final String path;
  final int depth;
  final bool ovaAncestor;
}
