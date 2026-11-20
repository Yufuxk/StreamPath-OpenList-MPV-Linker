import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/app_paths.dart';
import 'webdav_font_localizer.dart';
import 'webdav_font_matcher.dart';

/// 保存仍被视频续播入口引用的 WebDAV 字体目录。
class WebDavFontCache {
  WebDavFontCache({
    Directory? directory,
    WebDavFontLocalizer? localizer,
    DateTime Function()? now,
  }) : _directory = directory, // ignore: prefer_initializing_formals
       _localizer = localizer ?? const WebDavFontLocalizer(),
       _now = now ?? DateTime.now;

  final Directory? _directory;
  final WebDavFontLocalizer _localizer;
  final DateTime Function() _now;
  static const _weakVersionLifetime = Duration(days: 7);
  Future<void> _pending = Future<void>.value();

  static String sessionKey(String sourceId, String sessionId) =>
      sha256.convert(utf8.encode('$sourceId\u0000$sessionId')).toString();

  Future<Directory> _root() async {
    final cache = _directory ?? await AppPaths.cacheDirectory();
    final root = _directory ?? Directory(p.join(cache.path, 'webdav_fonts'));
    await root.create(recursive: true);
    return root;
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace stack) {},
    );
    return result;
  }

  Future<WebDavFontLocalizationResult?> localize({
    required WebDavFontDirectory source,
    required String sourceId,
    required String retentionSessionId,
    required Directory sessionBase,
    required String sessionId,
    required WebDavFontBytesLoader loader,
    WebDavFontFileLoader? fileLoader,
    required int maxFiles,
    required int maxBytes,
    required Duration timeout,
    required bool enabled,
    Iterable<String> mediaPaths = const [],
    Set<String>? retainPaths,
    void Function(WebDavFontLocalizationProgress progress)? onProgress,
  }) async {
    if (!enabled) {
      return _localizer.localize(
        source: source,
        base: sessionBase,
        sessionId: sessionId,
        loader: loader,
        fileLoader: fileLoader,
        maxFiles: maxFiles,
        maxBytes: maxBytes,
        timeout: timeout,
        onProgress: onProgress,
      );
    }
    try {
      return await _enqueue(() async {
        final root = await _root();
        final signature = sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  sourceId,
                  source.entryKey,
                  for (final file in source.files)
                    [file.url, file.size, file.etag, file.lastModified],
                ]),
              ),
            )
            .toString();
        final manifest = File(p.join(root.path, '$signature.json'));
        final cached = await _readManifest(manifest);
        final files = await _readFiles(root, cached);
        final expectedNames = [
          for (var i = 0; i < source.files.length; i++)
            '$i${source.files[i].extension}',
        ];
        final fits =
            files.length <= maxFiles &&
            files.values.fold(0, (sum, entry) => sum + entry.size) <= maxBytes;
        final complete =
            files.isNotEmpty &&
            fits &&
            files.length == expectedNames.length &&
            expectedNames.every(files.containsKey) &&
            await files.values.first.file.parent
                    .list(followLinks: false)
                    .length ==
                files.length;
        final checkedAt = cached?['checkedAt'];
        final date = _now();
        final weak = source.files.indexed
            .where((item) {
              final etag = item.$2.etag;
              return etag == null || etag.isEmpty || etag.startsWith('W/');
            })
            .map((item) => expectedNames[item.$1])
            .toSet();
        final expired =
            complete &&
            weak.isNotEmpty &&
            checkedAt is int &&
            date.millisecondsSinceEpoch - checkedAt >=
                _weakVersionLifetime.inMilliseconds;
        final refs = _strings(cached?['sessionKeys']).toSet()
          ..add(sessionKey(sourceId, retentionSessionId));
        final mediaKeys = _strings(cached?['mediaKeys']).toSet()
          ..addAll(mediaPaths.map((path) => sessionKey(sourceId, path)));

        Future<void> save(
          Directory directory,
          Iterable<_CachedFontFile> valid, {
          required bool complete,
          required int checkedAt,
        }) => _write(manifest, {
          'directory': p.basename(directory.path),
          'files': [for (final entry in valid) entry.toJson()],
          'complete': complete,
          'expected': source.files.length,
          'checkedAt': checkedAt,
          'sessionKeys': refs.toList(),
          'mediaKeys': mediaKeys.toList(),
        });

        WebDavFontLocalizationResult hit(Iterable<_CachedFontFile> entries) {
          final fonts = entries
              .map((entry) => entry.file)
              .toList(growable: false);
          final summary = WebDavFontSummary(
            source.files.length,
            fonts.length,
            fonts.length,
            const {},
          );
          onProgress?.call(
            WebDavFontLocalizationProgress(
              completedFiles: fonts.length,
              totalFiles: source.files.length,
              receivedBytes: 0,
              expectedBytes: 0,
              fileName: source.name,
              fromCache: true,
              summary: summary,
            ),
          );
          retainPaths?.add(fonts.first.parent.path);
          return WebDavFontLocalizationResult(
            directory: fonts.first.parent,
            files: fonts,
            persistent: true,
            summary: summary,
          );
        }

        Future<void> recordHit() async {
          if (checkedAt is! int ||
              refs.length != _strings(cached?['sessionKeys']).length ||
              mediaKeys.length != _strings(cached?['mediaKeys']).length) {
            await save(
              files.values.first.file.parent,
              files.values,
              complete: true,
              checkedAt: checkedAt is int
                  ? checkedAt
                  : date.millisecondsSinceEpoch,
            );
          }
        }

        if (complete && !expired) {
          await recordHit();
          return hit(files.values);
        }

        final localized = await _localizer.localize(
          source: source,
          base: root,
          sessionId: '${signature}_${DateTime.now().microsecondsSinceEpoch}',
          loader: loader,
          fileLoader: fileLoader,
          maxFiles: maxFiles,
          maxBytes: maxBytes,
          timeout: timeout,
          reuse: {
            for (final entry in files.entries)
              if (!expired || !weak.contains(entry.key))
                entry.key: entry.value.file,
          },
          onProgress: onProgress,
        );
        if (expired && localized?.summary.complete != true) {
          await localized?.directory.delete(recursive: true);
          await recordHit();
          return hit(files.values);
        }
        if (localized == null) return null;
        // 有效的旧目录可能正在被 MPV 使用，修复结果发布到新目录。
        // 剩余列表预算不足时，不用较小的副本替换已有缓存。
        if (!fits) return localized;
        try {
          final updated = <_CachedFontFile>[];
          for (final file in localized.files) {
            updated.add(await _CachedFontFile.inspect(file));
          }
          await save(
            localized.directory,
            updated,
            complete: localized.summary.complete,
            checkedAt: date.millisecondsSinceEpoch,
          );
        } on FileSystemException {
          return localized;
        }
        retainPaths?.add(localized.directory.path);
        return WebDavFontLocalizationResult(
          directory: localized.directory,
          files: localized.files,
          summary: localized.summary,
          persistent: true,
        );
      });
    } on FileSystemException {
      return _localizer.localize(
        source: source,
        base: sessionBase,
        sessionId: sessionId,
        loader: loader,
        fileLoader: fileLoader,
        maxFiles: maxFiles,
        maxBytes: maxBytes,
        timeout: timeout,
        onProgress: onProgress,
      );
    }
  }

  /// 来源不可用时，按此前实际匹配过的媒体路径复用完整字体目录。
  Future<WebDavFontLocalizationResult?> forCachedMedia({
    required String sourceId,
    required String mediaPath,
    required String retentionSessionId,
    Set<String>? retainPaths,
  }) => _enqueue(() async {
    final root = await _root();
    final key = sessionKey(sourceId, mediaPath);
    File? manifest;
    Map<String, dynamic>? match;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File || p.extension(entity.path) != '.json') continue;
      final data = await _readManifest(entity);
      if (data == null ||
          data['complete'] != true ||
          data['checkedAt'] is! int ||
          !_strings(data['mediaKeys']).contains(key)) {
        continue;
      }
      if (match == null ||
          (data['checkedAt'] as int) > (match['checkedAt'] as int)) {
        manifest = entity;
        match = data;
      }
    }
    if (match == null) return null;
    final validated = await _readFiles(root, match);
    if (validated.isEmpty ||
        validated.length != match['expected'] ||
        await validated.values.first.file.parent
                .list(followLinks: false)
                .length !=
            validated.length) {
      return null;
    }
    final refs = _strings(match['sessionKeys']).toSet();
    if (refs.add(sessionKey(sourceId, retentionSessionId))) {
      await _write(manifest!, {...match, 'sessionKeys': refs.toList()});
    }
    final files = validated.values
        .map((entry) => entry.file)
        .toList(growable: false);
    retainPaths?.add(files.first.parent.path);
    return WebDavFontLocalizationResult(
      directory: files.first.parent,
      files: files,
      persistent: true,
      summary: WebDavFontSummary(
        files.length,
        files.length,
        files.length,
        const {},
      ),
    );
  });

  static Iterable<String> _strings(Object? value) =>
      value is List ? value.whereType<String>() : const [];

  Future<Map<String, dynamic>?> _readManifest(File manifest) async {
    try {
      if (!await manifest.exists()) return null;
      final data = jsonDecode(await manifest.readAsString());
      return data is Map<String, dynamic> ? data : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<Map<String, _CachedFontFile>> _readFiles(
    Directory root,
    Map<String, dynamic>? data,
  ) async {
    final files = <String, _CachedFontFile>{};
    final name = data?['directory'];
    final rawFiles = data?['files'];
    if (name is! String ||
        !name.startsWith('streampath-fonts-') ||
        p.basename(name) != name ||
        rawFiles is! List ||
        rawFiles.length > WebDavFontLocalizer.maxFontFiles) {
      return files;
    }
    final directory = Directory(p.join(root.path, name));
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return files;
    }
    final present = await directory.list(followLinks: false).toList();
    for (final raw in rawFiles) {
      if (raw is! Map || raw['name'] is! String || raw['size'] is! int) {
        continue;
      }
      final name = raw['name'] as String;
      final size = raw['size'] as int;
      if (!RegExp(r'^\d+\.(ttf|otf|ttc|otc)$').hasMatch(name) ||
          size <= 0 ||
          size > WebDavFontLocalizer.maxFontBytes) {
        continue;
      }
      final file = File(p.join(directory.path, name));
      try {
        if (!present.any(
              (entity) => entity is File && p.equals(entity.path, file.path),
            ) ||
            await file.length() != size) {
          continue;
        }
        final actual = await _CachedFontFile.inspect(file);
        if (raw['sha256'] != null && actual.digest != raw['sha256']) continue;
        files[name] = actual;
      } on FileSystemException {
        // 该文件需要重新下载，其余通过校验的字体仍可复用。
      }
    }
    // MPV 会读取目录中的所有文件，额外文件也需要通过新目录隔离。
    return files;
  }

  Future<void> _write(File manifest, Map<String, dynamic> data) async {
    final temp = File('${manifest.path}.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    await temp.rename(manifest.path);
  }

  Future<void> prune(
    Future<Set<String>> Function() loadActiveSessionKeys, {
    Set<String> preservedPaths = const {},
    Set<String> Function()? activePaths,
  }) => _enqueue(() async {
    final activeSessionKeys = await loadActiveSessionKeys();
    final protected = {...preservedPaths, ...?activePaths?.call()};
    final root = await _root();
    final retainedDirectories = <String>{};
    await for (final entity in root.list()) {
      if (entity is! File || p.extension(entity.path) != '.json') continue;
      final Object? raw;
      try {
        raw = jsonDecode(await entity.readAsString());
      } on FormatException {
        await entity.delete();
        continue;
      }
      if (raw is! Map<String, dynamic>) {
        await entity.delete();
        continue;
      }
      final refs =
          (raw['sessionKeys'] as List?)?.whereType<String>() ??
          const <String>[];
      final name = raw['directory'];
      if (name is String &&
          name.startsWith('streampath-fonts-') &&
          p.basename(name) == name) {
        if (refs.any(activeSessionKeys.contains) ||
            protected.contains(p.join(root.path, name))) {
          retainedDirectories.add(name);
          continue;
        }
      }
      await entity.delete();
    }
    await for (final entity in root.list()) {
      if (entity is File && entity.path.endsWith('.json.tmp')) {
        await entity.delete();
        continue;
      }
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (protected.any(
        (path) => p.equals(entity.path, path) || p.isWithin(entity.path, path),
      )) {
        continue;
      }
      if (name.startsWith('streampath-fonts-') &&
          !retainedDirectories.contains(name)) {
        await entity.delete(recursive: true);
      }
    }
  });
}

class _CachedFontFile {
  const _CachedFontFile(this.file, this.size, this.digest);

  final File file;
  final int size;
  final String digest;

  static Future<_CachedFontFile> inspect(File file) async => _CachedFontFile(
    file,
    await file.length(),
    (await sha256.bind(file.openRead()).single).toString(),
  );

  Map<String, Object> toJson() => {
    'name': p.basename(file.path),
    'size': size,
    'sha256': digest,
  };
}
