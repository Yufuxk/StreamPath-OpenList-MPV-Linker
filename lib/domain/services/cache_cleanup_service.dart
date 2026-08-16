import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/utils/app_paths.dart';

typedef CacheStoreClearer = Future<void> Function();

/// 缓存清理结果。
class CacheCleanupResult {
  const CacheCleanupResult({
    required this.cacheDirectory,
    required this.deletedEntries,
    required this.clearedStores,
  });

  final String cacheDirectory;
  final int deletedEntries;
  final int clearedStores;
}

/// 缓存清理失败。
class CacheCleanupException implements Exception {
  const CacheCleanupException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// 播放器仍在运行，当前不能安全清理缓存。
class CacheCleanupBlockedException extends CacheCleanupException {
  const CacheCleanupBlockedException(super.message);
}

/// 设置页依赖的缓存清理接口，便于隔离界面与文件系统实现。
abstract interface class CacheCleaner {
  Future<CacheCleanupResult> clear();
}

/// 清除运行时缓存，并保留 `stream_path_data/config/` 下的全部配置。
///
/// Hive 与 SQLite 文件在程序运行时保持打开，因此先由 [storeClearers]
/// 清空内容，再删除 `cache/` 中其他文件。打开的存储文件本身会保留，
/// 但其中的用户数据已被清空。
class CacheCleanupService implements CacheCleaner {
  CacheCleanupService({
    required List<CacheStoreClearer> storeClearers,
    Future<Directory> Function()? dataDirectoryProvider,
    Set<String> preservedCacheNames = const {},
    bool deleteRuntimeFiles = true,
  }) : _storeClearers = List.unmodifiable(storeClearers),
       _dataDirectoryProvider = dataDirectoryProvider ?? AppPaths.dataDirectory,
       _preservedCacheNames = preservedCacheNames
           .map((name) => name.toLowerCase())
           .toSet(),
       // ignore: prefer_initializing_formals
       _deleteRuntimeFiles = deleteRuntimeFiles;

  final List<CacheStoreClearer> _storeClearers;
  final Future<Directory> Function() _dataDirectoryProvider;
  final Set<String> _preservedCacheNames;
  final bool _deleteRuntimeFiles;
  bool _clearing = false;

  @override
  Future<CacheCleanupResult> clear() async {
    if (_clearing) {
      throw const CacheCleanupException('缓存正在清理，请稍候');
    }
    _clearing = true;
    try {
      final dataDir = await _validatedDataDirectory();
      final cacheDir = Directory(p.join(dataDir.path, AppPaths.cacheDirName));
      await cacheDir.create(recursive: true);
      await _validateDirectory(cacheDir, expectedParent: dataDir);

      var clearedStores = 0;
      for (final clearStore in _storeClearers) {
        await clearStore();
        clearedStores++;
      }

      final targets = _deleteRuntimeFiles
          ? [
              ...await _collectCacheTargets(cacheDir),
              ...await _collectLegacyTargets(dataDir),
            ]
          : <FileSystemEntity>[];
      for (final target in targets) {
        await _deleteTarget(target);
      }

      return CacheCleanupResult(
        cacheDirectory: cacheDir.path,
        deletedEntries: targets.length,
        clearedStores: clearedStores,
      );
    } on CacheCleanupException {
      rethrow;
    } catch (error) {
      throw CacheCleanupException('清理缓存失败：$error', error);
    } finally {
      _clearing = false;
    }
  }

  Future<Directory> _validatedDataDirectory() async {
    final dataDir = await _dataDirectoryProvider();
    if (!await dataDir.exists()) {
      throw const CacheCleanupException('找不到应用数据目录');
    }
    if (!_sameName(p.basename(dataDir.path), AppPaths.dataDirName)) {
      throw CacheCleanupException('拒绝清理非应用数据目录：${dataDir.path}');
    }
    await _validateDirectory(dataDir);
    return dataDir;
  }

  Future<void> _validateDirectory(
    Directory directory, {
    Directory? expectedParent,
  }) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.directory) {
      throw CacheCleanupException('拒绝清理无效目录：${directory.path}');
    }
    if (expectedParent != null) {
      final parentPath = p.normalize(p.absolute(p.dirname(directory.path)));
      final expectedPath = p.normalize(p.absolute(expectedParent.path));
      if (!_samePath(parentPath, expectedPath)) {
        throw CacheCleanupException('缓存目录不在应用数据目录内：${directory.path}');
      }
    }
  }

  Future<List<FileSystemEntity>> _collectCacheTargets(
    Directory cacheDir,
  ) async {
    final targets = <FileSystemEntity>[];
    await for (final entity in cacheDir.list(followLinks: false)) {
      final name = p.basename(entity.path).toLowerCase();
      if (_isOpenStoreFile(name) || _preservedCacheNames.contains(name)) {
        continue;
      }
      await _validateDeleteTarget(entity, cacheDir);
      targets.add(entity);
    }
    return targets;
  }

  Future<List<FileSystemEntity>> _collectLegacyTargets(
    Directory dataDir,
  ) async {
    final targets = <FileSystemEntity>[];
    await for (final entity in dataDir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!_isLegacyCacheName(name)) continue;
      await _validateDeleteTarget(entity, dataDir);
      targets.add(entity);
    }
    return targets;
  }

  Future<void> _validateDeleteTarget(
    FileSystemEntity entity,
    Directory allowedParent,
  ) async {
    final parentPath = p.normalize(p.absolute(p.dirname(entity.path)));
    final allowedPath = p.normalize(p.absolute(allowedParent.path));
    if (!_samePath(parentPath, allowedPath)) {
      throw CacheCleanupException('拒绝删除缓存目录外的目标：${entity.path}');
    }
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw CacheCleanupException('拒绝删除重解析点：${entity.path}');
    }
    if (type == FileSystemEntityType.directory) {
      await for (final child in Directory(
        entity.path,
      ).list(recursive: true, followLinks: false)) {
        final childType = await FileSystemEntity.type(
          child.path,
          followLinks: false,
        );
        if (childType == FileSystemEntityType.link) {
          throw CacheCleanupException('拒绝删除包含重解析点的目录：${entity.path}');
        }
      }
    }
  }

  Future<void> _deleteTarget(FileSystemEntity target) async {
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      await File(target.path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(target.path).delete(recursive: true);
    }
  }

  static bool _isOpenStoreFile(String name) =>
      name == 'directory_cache.hive' ||
      name == 'directory_cache.lock' ||
      name.startsWith('streampath.db') ||
      name.startsWith('audio_streampath.db');

  static bool _isLegacyCacheName(String name) {
    final lower = name.toLowerCase();
    const exact = <String>{
      'streampath.db',
      'audio_streampath.db',
      'playback_history.json',
      'audio_playback_history.json',
      'directory_cache',
      'directory_cache.hive',
      'directory_cache.lock',
      'mpv-current.txt',
      'mpv-command.txt',
      'mpv-watch-later',
      'mpv-audio-watch-later',
      'mpv-scripts',
      'streampath-playlist.m3u',
      'mpv.log',
      'media_metadata.json',
      'cache_intelligence_learning.json',
      'clipboard_history_fix.log',
    };
    if (exact.contains(lower) || lower.endsWith('.lua')) return true;
    return lower.startsWith('mpv-current-') ||
        lower.startsWith('mpv-command-') ||
        lower.startsWith('mpv-progress-') ||
        lower.startsWith('mpv-audio-current-') ||
        lower.startsWith('mpv-audio-command-') ||
        lower.startsWith('mpv-audio-progress-') ||
        lower.startsWith('streampath-playlist-') ||
        lower.startsWith('streampath-audio-');
  }

  static bool _samePath(String left, String right) => Platform.isWindows
      ? left.toLowerCase() == right.toLowerCase()
      : left == right;

  static bool _sameName(String left, String right) => Platform.isWindows
      ? left.toLowerCase() == right.toLowerCase()
      : left == right;
}
