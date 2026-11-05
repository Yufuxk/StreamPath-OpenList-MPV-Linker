import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/errors/app_exception.dart';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_directory_exclusions.dart';
import '../../data/models/film_fast_task.dart';
import '../../data/models/media_source.dart';
import '../repositories/media_directory_source.dart';
import 'film_catalog_matcher.dart';
import 'film_catalog_scanner.dart';
import 'film_scan_parser_pool.dart';
import 'local_media_source.dart';
import 'native_storage_source.dart';
import 'webdav_media_source_adapter.dart';

/// 数据库保存队列；内存只持有当前并发窗口和任务内资料缓存。
class FilmFastTaskRunner {
  FilmFastTaskRunner({
    required this.store,
    required this.matcher,
    required this.sourceFor,
    required this.onProgress,
    required this.onStop,
  });
  final FilmCatalogStore store;
  final FilmCatalogMatcher matcher;
  final MediaDirectorySource Function(FilmCatalogRoot) sourceFor;
  final Future<void> Function() onProgress;
  final void Function() onStop;
  final _parser = FilmScanParserPool();
  final _cancel = CancelToken();
  final _roots = <int, FilmCatalogRoot>{};
  final _sources = <int, MediaDirectorySource>{};
  final _sessions = <int, FilmScanMetadataSession>{};
  final _directoryCounts = <String, int>{};
  final _directoryWaiters = <Completer<void>>[];
  int _directoryActive = 0;
  bool _stopping = false;
  Object? _firstFailure;
  StackTrace? _failureStack;
  bool _scanDone = false;
  Completer<void>? _wake;
  Future<void>? _running;
  final _clock = Stopwatch();
  int _elapsed = 0;

  static Future<Map<String, dynamic>> snapshot(
    FilmCatalogStore store,
    FilmCatalogMatcher matcher,
    FilmCatalogRoot root,
    MediaDirectorySource source,
  ) async {
    final files = await matcher.filesFor?.call(root);
    return {
      'sourceId': root.sourceId,
      'kind': root.sourceKind.name,
      'rootPath': root.path,
      'type': root.type.name,
      'enabled': root.enabled,
      'language': await store.language(),
      'exclusions': (await store.directoryExclusions()).toJson(),
      'probeMode': await store.probeMode(),
      'localMetadata': files?.localMode ?? false,
      'writeBack': files?.canWrite ?? false,
      'connection': source is NativeStorageSource
          ? source.config.toJson()
          : source is LocalMediaSource
          ? source.root.path
          : source is WebDavMediaSourceAdapter
          ? {
              // 地址可能带签名参数，仅保存身份摘要用于恢复核对。
              'endpointHash': sha256
                  .convert(utf8.encode(source.service.baseUrl))
                  .toString(),
              'username': source.service.credentialSnapshot.username,
            }
          : source.descriptor.displayName,
    };
  }

  void _check() {
    if (_stopping) throw const FilmCatalogException('cancelled');
  }

  void _signal() {
    _wake?.complete();
    _wake = null;
  }

  void stop() {
    if (_stopping) return;
    _stopping = true;
    onStop();
    _cancel.cancel();
    matcher.tmdb.stopFullSpeed();
    _wakeDirectories();
    for (final source in _sources.values.toSet()) {
      if (source is NativeStorageSource) source.reader.cancelCurrent();
    }
    _signal();
  }

  Future<void> pause() async {
    stop();
    await _running;
  }

  Future<void> run() => _running ??= _run();

  Future<void> _run() async {
    var completed = false;
    String? failure;
    final task = (await store.fastTask())!;
    _elapsed = task.elapsedMs;
    _clock.start();
    try {
      for (final entry in await store.fastRoots()) {
        _check();
        final root = await store.root(entry.rootId);
        if (root == null ||
            root.sourceKind.isMediaServer ||
            root.generation != entry.generation) {
          throw const FilmCatalogException('fastCheckpointChanged');
        }
        final source = sourceFor(root);
        if (source.descriptor.sourceId != root.sourceId ||
            source.descriptor.kind != root.sourceKind) {
          throw const FilmCatalogException('sourceUnavailable');
        }
        if (jsonEncode(await snapshot(store, matcher, root, source)) !=
            jsonEncode(entry.snapshot)) {
          throw const FilmCatalogException('fastCheckpointChanged');
        }
        _roots[root.id] = root;
        _sources[root.id] = source;
        final session = await matcher.scanSession(
          root,
          cancelled: () => _stopping,
          lazyBindings: true,
        );
        if (!session.enabled) {
          throw FilmCatalogException(session.error ?? 'noToken');
        }
        _sessions[root.id] = session;
        final files = session.files;
        if (files != null) {
          final fileSource = files.source;
          if (fileSource is WebDavMediaSourceAdapter &&
              fileSource is! NativeStorageSource) {
            files.byteReader = (path, limit) async => Uint8List.fromList(
              await fileSource.service.fetchTaskFileBytes(
                fileSource.service.resolveUrl(path),
                maxBytes: limit,
                timeout: const Duration(seconds: 30),
                cancelToken: _cancel,
              ),
            );
          }
          files.directoryReader = (path) => _withDirectoryPermit(
            root,
            () =>
                fileSource is WebDavMediaSourceAdapter &&
                    fileSource is! NativeStorageSource
                ? fileSource.service.fetchFastCatalogDirectory(
                    path,
                    cancelToken: _cancel,
                    parse: _parser.parse,
                  )
                : fileSource.fetchDirectory(path, forceRefresh: true),
          );
        }
      }
      _check();
      matcher.tmdb.beginFullSpeed();
      await store.setFastStatus('running');
      await onProgress();
      await Future.wait([_guard(() => _scan(task)), _guard(_scrape)]);
      _check();
      for (final root in _roots.values) {
        await matcher.resolveConflicts(root.id);
        _check();
        await matcher.assignExtras(root.id);
      }
      await store.setMatcherVersion(FilmCatalogMatcher.matchingVersion);
      await store.reconcilePlaylists();
      _check();
      await store.discardFastTask();
      completed = true;
    } catch (error, stack) {
      final cause = _firstFailure ?? error;
      failure = switch (cause) {
        FilmCatalogException() => cause.code == 'cancelled' ? null : cause.code,
        DatabaseException() => 'catalogStorageFailed',
        AppException() => _sourceErrorCode(cause),
        FileSystemException() => 'directoryReadFailed',
        TimeoutException() => 'metadataTimeout',
        _ => 'fastTaskFailed',
      };
      if (failure == 'fastTaskFailed') {
        Error.throwWithStackTrace(cause, _failureStack ?? stack);
      }
    } finally {
      if (completed) {
        _stopping = true;
        _cancel.cancel();
      } else {
        stop();
      }
      try {
        await _parser.close();
      } finally {
        matcher.tmdb.endFullSpeed();
        _clock.stop();
        if (!completed) {
          await store.setFastStatus(
            'paused',
            error: failure,
            elapsedMs: _elapsed + _clock.elapsedMilliseconds,
          );
        }
        _sessions.clear();
        await onProgress();
      }
    }
  }

  void _fail(Object error, StackTrace stack) {
    if (_firstFailure == null &&
        !(error is FilmCatalogException && error.code == 'cancelled')) {
      _firstFailure = error;
      _failureStack = stack;
    }
    stop();
  }

  Future<void> _guard(Future<void> Function() work) async {
    try {
      await work();
    } catch (error, stack) {
      if (_cancelledIo(error)) throw const FilmCatalogException('cancelled');
      _fail(error, stack);
      rethrow;
    }
  }

  bool _cancelledIo(Object error) =>
      _cancel.isCancelled &&
      error is AppException &&
      error.cause is DioException &&
      (error.cause as DioException).type == DioExceptionType.cancel;

  String _sourceErrorCode(AppException error) {
    final cause = error.cause;
    if (cause is! DioException) return 'directoryReadFailed';
    return switch (cause.response?.statusCode) {
      401 || 403 => 'fastSourceAuthenticationFailed',
      429 => 'fastSourceRateLimited',
      _ => switch (cause.type) {
        DioExceptionType.connectionError ||
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => 'fastSourceConnectionFailed',
        _ => 'directoryReadFailed',
      },
    };
  }

  Future<void> _scan(FilmFastTask task) async {
    final exclusions = await store.directoryExclusions();
    for (final entry in await store.fastRoots()) {
      _check();
      final root = _roots[entry.rootId]!;
      await store.pruneExcludedDirectories(
        root,
        exclusions,
        scopePath: entry.scope,
      );
      if (!entry.seeded) {
        var after = entry.afterId;
        while (!_stopping) {
          final rows = await store.scrapeEntries(
            root.id,
            afterId: after,
            incremental: task.incremental,
            limit: 128,
          );
          _check();
          await store.seedFastScraping(root, rows);
          _signal();
          if (rows.isEmpty) break;
          after = rows.last.$1;
        }
      }
    }
    while (!_stopping) {
      final bySource = <String, int>{};
      final jobs = <FilmFastJob>[];
      for (final taskRoot in await store.fastRoots()) {
        if (taskRoot.scanComplete) continue;
        final available = await store.fastJobs(
          'directory',
          rootId: taskRoot.rootId,
        );
        for (final job in available) {
          final root = _roots[job.rootId]!;
          final source = _sources[root.id]!;
          final key =
              source is WebDavMediaSourceAdapter &&
                  source is! NativeStorageSource
              ? Uri.parse(source.service.baseUrl).origin
              : root.sourceId;
          final limit = root.sourceKind == MediaSourceKind.local
              ? Platform.numberOfProcessors.clamp(4, 32)
              : root.sourceKind.isNativeStorage
              ? 1
              : 8;
          if ((bySource[key] ?? 0) >= limit) continue;
          bySource[key] = (bySource[key] ?? 0) + 1;
          jobs.add(job);
          if (jobs.length == 32) break;
        }
        if (jobs.length == 32) break;
      }
      if (jobs.isEmpty) break;
      await store.claimFastJobs(jobs);
      final results = await Future.wait(
        jobs.map((job) => _guardDirectory(job, exclusions, task.incremental)),
      );
      for (var i = 0; i < jobs.length; i++) {
        _check();
        final job = jobs[i];
        final taskRoot = (await store.fastRoots()).firstWhere(
          (root) => root.rootId == job.rootId,
        );
        await store.stageFastDirectory(
          _roots[job.rootId]!,
          taskRoot,
          job,
          results[i].$1,
          results[i].$2,
        );
        _signal();
      }
      await _finishScans(task);
      await _report();
    }
    _check();
    await _finishScans(task);
    _scanDone = true;
    _signal();
  }

  Future<void> _finishScans(FilmFastTask task) async {
    for (final root in await store.fastRoots()) {
      if (!root.scanComplete &&
          !await store.fastDirectoryPending(root.rootId)) {
        _check();
        await store.commitFastScan(root, task.incremental, () => _stopping);
      }
    }
    _signal();
  }

  Future<(List<FilmScanEntry>, List<String>)> _guardDirectory(
    FilmFastJob job,
    FilmDirectoryExclusions exclusions,
    bool incremental,
  ) async {
    try {
      _check();
      final root = _roots[job.rootId]!;
      if (exclusions.excludesPath(job.path)) {
        return (<FilmScanEntry>[], <String>[]);
      }
      if (FilmCatalogScanner.excludedDirectory(root.path.split('/').last)) {
        throw const FilmCatalogException('unsupportedDirectory');
      }
      final source = _sources[root.id]!;
      final entries = await _withDirectoryPermit(
        root,
        () async => source is NativeStorageSource
            ? await source.fetchCatalogDirectory(job.path)
            : source is WebDavMediaSourceAdapter
            ? await source.service.fetchFastCatalogDirectory(
                job.path,
                cancelToken: _cancel,
                parse: _parser.parse,
              )
            : source is LocalMediaSource
            ? await source.fetchFastCatalogDirectory(job.path, () => _stopping)
            : await source.fetchDirectory(job.path, forceRefresh: true),
      );
      _check();
      final collected = FilmCatalogScanner.collectDirectory(
        root,
        source,
        job.path,
        entries,
        exclusions,
        const {},
      );
      if (!incremental || collected.$1.isEmpty) return collected;
      final known = await store.fastKnownPaths(
        root.id,
        collected.$1.map((e) => filmPathKey(e.path, root.sourceKind)).toList(),
      );
      return (
        collected.$1
            .where((e) => !known.contains(filmPathKey(e.path, root.sourceKind)))
            .toList(),
        collected.$2,
      );
    } catch (error, stack) {
      if (_cancelledIo(error)) {
        throw const FilmCatalogException('cancelled');
      }
      _fail(error, stack);
      rethrow;
    }
  }

  Future<void> _scrape() async {
    while (!_stopping) {
      // 在查询之前挂起唤醒点，避免目录登记和等待之间遗漏通知。
      final wake = _wake ??= Completer<void>();
      final available = await store.fastJobs('scrape', limit: 8);
      if (available.isEmpty) {
        if (_scanDone) return;
        await wake.future;
        continue;
      }
      final roots = await store.fastRoots();
      final firstOrdinal = roots
          .firstWhere((root) => root.rootId == available.first.rootId)
          .ordinal;
      if (roots.any(
        (root) =>
            root.ordinal < firstOrdinal && (!root.scanComplete || !root.seeded),
      )) {
        await wake.future;
        continue;
      }
      final first = available.first;
      final session = _sessions[first.rootId]!;
      final jobs = available
          .takeWhile((job) => job.rootId == first.rootId)
          .toList();
      if (session.files?.localMode == true) jobs.removeRange(1, jobs.length);
      await store.claimFastJobs(jobs);
      await Future.wait(
        jobs.map(
          (job) => _guard(() async {
            _check();
            await session.prepare([
              FilmScanEntry(
                path: job.path,
                parentPath: job.parent,
                name: job.name,
                mediaKind: job.mediaKind,
              ),
            ], deferLocalFallback: session.files?.localMode != true);
            if (session.paused) throw FilmCatalogException(session.error!);
          }),
        ),
      );
      _check();
      if (session.files != null && session.files?.localMode != true) {
        for (final job in jobs) {
          _check();
          final key = filmPathKey(job.path, session.root.sourceKind);
          if (session.matches.containsKey(key)) continue;
          await session.prepare([
            FilmScanEntry(
              path: job.path,
              parentPath: job.parent,
              name: job.name,
              mediaKind: job.mediaKind,
            ),
          ]);
          if (session.paused) throw FilmCatalogException(session.error!);
        }
      }
      _check();
      final matches = <String, FilmScanMatch>{};
      for (final job in jobs) {
        final key = filmPathKey(job.path, session.root.sourceKind);
        final match = session.matches[key];
        if (match != null) matches[key] = match;
      }
      if (matches.values.any((match) => match.origin == 'nfo')) {
        for (final job in jobs) {
          _check();
          final key = filmPathKey(job.path, session.root.sourceKind);
          final match = matches[key];
          await store.completeFastScraping(first.rootId, [
            job,
          ], match == null ? {} : {key: match});
        }
      } else {
        await store.completeFastScraping(first.rootId, jobs, matches);
      }
      session.releaseCommitted(
        jobs.map((job) => filmPathKey(job.path, session.root.sourceKind)),
      );
      await _report();
    }
  }

  void _wakeDirectories() {
    for (final waiter in _directoryWaiters) {
      waiter.complete();
    }
    _directoryWaiters.clear();
  }

  Future<T> _withDirectoryPermit<T>(
    FilmCatalogRoot root,
    Future<T> Function() read,
  ) async {
    final source = _sources[root.id]!;
    final key = root.sourceKind == MediaSourceKind.webdav
        ? Uri.parse((source as WebDavMediaSourceAdapter).service.baseUrl).origin
        : root.sourceId;
    final limit = root.sourceKind == MediaSourceKind.local
        ? Platform.numberOfProcessors.clamp(4, 32)
        : root.sourceKind.isNativeStorage
        ? 1
        : 8;
    while (_directoryActive >= 32 || (_directoryCounts[key] ?? 0) >= limit) {
      _check();
      final waiter = Completer<void>();
      _directoryWaiters.add(waiter);
      await waiter.future;
    }
    _check();
    _directoryActive++;
    _directoryCounts[key] = (_directoryCounts[key] ?? 0) + 1;
    try {
      return await read();
    } finally {
      _directoryActive--;
      _directoryCounts[key] = _directoryCounts[key]! - 1;
      _wakeDirectories();
    }
  }

  Future<void> _report() async {
    await store.setFastStatus(
      _stopping ? 'stopping' : 'running',
      elapsedMs: _elapsed + _clock.elapsedMilliseconds,
    );
    await onProgress();
  }
}
