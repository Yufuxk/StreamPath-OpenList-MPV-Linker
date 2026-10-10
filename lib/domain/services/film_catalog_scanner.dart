import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../../core/errors/app_exception.dart';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/media_source.dart';
import '../repositories/media_directory_source.dart';
import 'local_media_source.dart';
import 'special_video_playlist_collector.dart';
import 'webdav_media_source_adapter.dart';

class FilmScanProgress {
  const FilmScanProgress(
    this.rootId,
    this.directories,
    this.files,
    this.path, {
    this.cancelling = false,
  });
  final int rootId, directories, files;
  final String path;
  final bool cancelling;
}

class FilmScanScope {
  const FilmScanScope(this.rootId, this.path);
  final int rootId;
  final String path;
}

/// 串行登记已发现资源，完整成功后确认缺失；无媒体探测请求。
class FilmCatalogScanner {
  FilmCatalogScanner(
    this.store, {
    this.remoteInterval = const Duration(seconds: 1),
  });
  final FilmCatalogStore store;
  final Duration remoteInterval;
  bool _busy = false;
  bool _cancelled = false;
  Future<void>? _running;
  bool get busy => _busy;

  void cancel() => _cancelled = true;
  Future<void> shutdown() async {
    cancel();
    await _running;
  }

  static bool excludedDirectory(String name) =>
      ['bdmv', 'certificate', 'video_ts'].contains(name.toLowerCase());

  Future<void> scan(
    FilmCatalogRoot root,
    MediaDirectorySource source, {
    void Function(FilmScanProgress)? onProgress,
    Future<void> Function(List<FilmScanEntry>)? onEntries,
    bool incremental = false,
    FilmScanScope? scope,
  }) {
    if (_busy) throw const FilmCatalogException('scanBusy');
    if (source.descriptor.sourceId != root.sourceId ||
        source.descriptor.kind != root.sourceKind) {
      throw const FilmCatalogException('sourceUnavailable');
    }
    if (scope != null &&
        (scope.rootId != root.id ||
            !filmPathWithin(
              filmPathKey(scope.path, root.sourceKind),
              filmPathKey(root.path, root.sourceKind),
            ))) {
      throw const FilmCatalogException('invalidPath');
    }
    _busy = true;
    _cancelled = false;
    final task = _scan(root, source, onProgress, onEntries, incremental, scope)
        .whenComplete(() {
          _busy = false;
        });
    // 关闭只等待任务结束，扫描错误仍由返回的 task 交给调用者处理。
    _running = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  void _checkCancelled() {
    if (_cancelled) throw const FilmCatalogException('cancelled');
  }

  Future<void> _scan(
    FilmCatalogRoot root,
    MediaDirectorySource source,
    void Function(FilmScanProgress)? report,
    Future<void> Function(List<FilmScanEntry>)? onEntries,
    bool incremental,
    FilmScanScope? scope,
  ) async {
    final generation = await store.beginScan(root.id);
    var directories = 0;
    var files = 0;
    try {
      final exclusions = await store.directoryExclusions();
      _checkCancelled();
      await store.pruneExcludedDirectories(
        root,
        exclusions,
        scopePath: scope?.path,
      );
      _checkCancelled();
      final known = {
        if (incremental)
          for (final resource in await store.resources(rootId: root.id))
            if (resource.availability == 'present') resource.pathKey,
      };
      if (root.path.isNotEmpty &&
          excludedDirectory(root.path.split('/').last)) {
        throw const FilmCatalogException('unsupportedDirectory');
      }
      final queue = Queue<String>()..add(scope?.path ?? root.path);
      final visited = <String>{};
      while (queue.isNotEmpty) {
        _checkCancelled();
        final path = queue.removeFirst();
        if (exclusions.excludesPath(path)) continue;
        if (!visited.add(filmPathKey(path, root.sourceKind))) continue;
        report?.call(FilmScanProgress(root.id, directories, files, path));
        if (source.descriptor.kind != MediaSourceKind.local &&
            directories > 0) {
          await Future<void>.delayed(remoteInterval);
          _checkCancelled();
        }
        final entries = source is LocalMediaSource
            ? await source.fetchCatalogDirectory(path)
            : source is WebDavMediaSourceAdapter
            ? await source.fetchCatalogDirectory(path)
            : await source.fetchDirectory(path, forceRefresh: true);
        _checkCancelled();
        directories++;
        if (entries.any(
          (e) =>
              e.isDirectory &&
              !e.isSelfEntry &&
              e.name.toLowerCase() == 'video_ts',
        )) {
          if (path == root.path) {
            throw const FilmCatalogException('unsupportedDirectory');
          }
          continue;
        }
        final staging = <FilmScanEntry>[];
        if (entries.any(
          (e) =>
              e.isDirectory && !e.isSelfEntry && e.name.toLowerCase() == 'bdmv',
        )) {
          if (!known.contains(filmPathKey(path, root.sourceKind))) {
            staging.add(
              FilmScanEntry(
                path: path,
                parentPath: path.contains('/')
                    ? path.substring(0, path.lastIndexOf('/'))
                    : '',
                name: path.isEmpty ? root.displayName : path.split('/').last,
                mediaKind: 'bdmv',
              ),
            );
          }
          await store.stage(root, generation, staging);
          files += staging.length;
          if (staging.isNotEmpty) await onEntries?.call(staging);
          _checkCancelled();
          continue;
        }
        for (final entry in entries) {
          if (entry.isSelfEntry) continue;
          if (entry.isDirectory &&
              (excludedDirectory(entry.name) ||
                  exclusions.excludesName(entry.name))) {
            continue;
          }
          final playable =
              !entry.isDirectory &&
              (entry.isIso ||
                  entry.isVideo ||
                  (root.sourceKind != MediaSourceKind.local && entry.isStrm));
          if (!entry.isDirectory && !playable) continue;
          final child = SpecialVideoPlaylistCollector.directChildPath(
            source,
            path,
            entry,
          );
          if (child == null) throw const FilmCatalogException('invalidPath');
          validateFilmPath(child);
          if (entry.isDirectory) {
            queue.add(child);
          } else {
            if (known.contains(filmPathKey(child, root.sourceKind))) continue;
            staging.add(
              FilmScanEntry(
                path: child,
                parentPath: path,
                name: entry.name,
                mediaKind: entry.isIso
                    ? 'iso'
                    : entry.isStrm
                    ? 'strm'
                    : 'video',
              ),
            );
          }
        }
        await store.stage(root, generation, staging);
        files += staging.length;
        report?.call(
          FilmScanProgress(
            root.id,
            directories,
            files,
            path,
            cancelling: _cancelled,
          ),
        );
        if (staging.isNotEmpty) await onEntries?.call(staging);
        _checkCancelled();
        await Future<void>.delayed(Duration.zero);
      }
      _checkCancelled();
      await store.commitScan(
        root.id,
        generation,
        cancelled: () => _cancelled,
        incremental: incremental,
        scopePath: scope?.path,
      );
    } on FilmCatalogException catch (error) {
      await store.finishScan(
        root.id,
        generation,
        error.code == 'cancelled' ? 'cancelled' : 'failed',
        error.code,
      );
      rethrow;
    } on AppException {
      await store.finishScan(
        root.id,
        generation,
        'failed',
        'directoryReadFailed',
      );
      throw const FilmCatalogException('directoryReadFailed');
    } on FileSystemException {
      await store.finishScan(
        root.id,
        generation,
        'failed',
        'directoryReadFailed',
      );
      throw const FilmCatalogException('directoryReadFailed');
    } on TimeoutException {
      await store.finishScan(
        root.id,
        generation,
        'failed',
        'directoryReadFailed',
      );
      throw const FilmCatalogException('directoryReadFailed');
    } catch (error) {
      // 保存失败状态后明确传播内部错误，不继续提交清单。
      await store.finishScan(root.id, generation, 'failed', 'scanFailed');
      rethrow;
    }
  }
}
