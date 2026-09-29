import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/app_paths.dart';
import 'webdav_font_localizer.dart';
import 'webdav_font_matcher.dart';

/// 保存仍被视频续播入口引用的 WebDAV 字体目录。
class WebDavFontCache {
  WebDavFontCache({Directory? directory, WebDavFontLocalizer? localizer})
    : _directory = directory, // ignore: prefer_initializing_formals
      _localizer = localizer ?? const WebDavFontLocalizer();

  final Directory? _directory;
  final WebDavFontLocalizer _localizer;
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
        final refs = {sessionKey(sourceId, retentionSessionId)};
        final cached = await _read(manifest, root);
        final cachedBytes = cached == null
            ? 0
            : await Future.wait(
                cached.$1.files.map((file) => file.length()),
              ).then((sizes) => sizes.fold<int>(0, (sum, size) => sum + size));
        if (cached != null &&
            cached.$1.files.length <= maxFiles &&
            cachedBytes <= maxBytes) {
          final existing =
              (cached.$2['sessionKeys'] as List?)
                  ?.whereType<String>()
                  .toSet() ??
              <String>{};
          final oldCount = existing.length;
          existing.addAll(refs);
          if (existing.length != oldCount) {
            await _write(manifest, {
              ...cached.$2,
              'sessionKeys': existing.toList(),
            });
          }
          onProgress?.call(
            WebDavFontLocalizationProgress(
              completedFiles: cached.$1.files.length,
              totalFiles: cached.$1.files.length,
              receivedBytes: 0,
              expectedBytes: 0,
              fileName: source.name,
              fromCache: true,
            ),
          );
          return cached.$1;
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
          onProgress: onProgress,
        );
        if (localized == null) return null;
        if (localized.files.length != source.files.length) return localized;
        try {
          await _write(manifest, {
            'directory': p.basename(localized.directory.path),
            'files': [
              for (final file in localized.files)
                {'name': p.basename(file.path), 'size': await file.length()},
            ],
            'sessionKeys': refs.toList(),
          });
        } on FileSystemException {
          return localized;
        }
        return WebDavFontLocalizationResult(
          directory: localized.directory,
          files: localized.files,
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

  Future<(WebDavFontLocalizationResult, Map<String, dynamic>)?> _read(
    File manifest,
    Directory root,
  ) async {
    if (!await manifest.exists()) return null;
    try {
      final data = jsonDecode(await manifest.readAsString());
      if (data is! Map<String, dynamic>) return null;
      final name = data['directory'];
      final rawFiles = data['files'];
      if (name is! String ||
          !name.startsWith('streampath-fonts-') ||
          p.basename(name) != name ||
          rawFiles is! List ||
          rawFiles.isEmpty) {
        return null;
      }
      final directory = Directory(p.join(root.path, name));
      if (!await directory.exists()) return null;
      final files = <File>[];
      for (final raw in rawFiles) {
        if (raw is! Map || raw['name'] is! String || raw['size'] is! int) {
          return null;
        }
        final fileName = raw['name'] as String;
        final size = raw['size'] as int;
        if (p.basename(fileName) != fileName || size <= 0) return null;
        final file = File(p.join(directory.path, fileName));
        if (!await file.exists() || await file.length() != size) return null;
        files.add(file);
      }
      return (
        WebDavFontLocalizationResult(
          directory: directory,
          files: List.unmodifiable(files),
          persistent: true,
        ),
        data,
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _write(File manifest, Map<String, dynamic> data) async {
    final temp = File('${manifest.path}.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    if (await manifest.exists()) {
      await manifest.delete();
    }
    await temp.rename(manifest.path);
  }

  Future<void> prune(Future<Set<String>> Function() loadActiveSessionKeys) =>
      _enqueue(() async {
        final activeSessionKeys = await loadActiveSessionKeys();
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
            if (refs.any(activeSessionKeys.contains)) {
              retainedDirectories.add(name);
              continue;
            }
          }
          await entity.delete();
        }
        await for (final entity in root.list()) {
          if (entity is! Directory) continue;
          final name = p.basename(entity.path);
          if (name.startsWith('streampath-fonts-') &&
              !retainedDirectories.contains(name)) {
            await entity.delete(recursive: true);
          }
        }
      });
}
