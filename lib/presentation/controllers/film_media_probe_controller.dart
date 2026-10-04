import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../domain/repositories/media_directory_source.dart';
import '../../domain/services/film_probe_access.dart';
import '../../domain/services/media_info_probe.dart';

typedef FilmPlaybackSnapshot = ({
  String sourceId,
  String target,
  String snapshotPath,
  String? resourcePath,
});

/// 默认只读取播放器快照；完整探测在无播放与准备任务时串行执行。
class FilmMediaProbeController extends ChangeNotifier {
  FilmMediaProbeController({
    required this.store,
    required this.sourceFor,
    required this.snapshots,
    required this.relativePathFor,
    required this.isPlaying,
    MediaInfoProbe? probe,
    FilmProbeAccess? access,
  }) : _probe = probe ?? MediaInfoProbe(),
       _access = access ?? FilmProbeAccess();

  void start() {
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => tick());
  }

  void stop() {
    _closed = true;
    _timer?.cancel();
  }

  final FilmCatalogStore store;
  final MediaDirectorySource Function(FilmCatalogRoot) sourceFor;
  final List<FilmPlaybackSnapshot> Function() snapshots;
  final String? Function(FilmPlaybackSnapshot) relativePathFor;
  final Future<bool> Function() isPlaying;
  final MediaInfoProbe _probe;
  final FilmProbeAccess _access;
  final Map<String, int> _seen = {};
  @visibleForTesting
  int get retainedSnapshotCount => _seen.length;
  Timer? _timer;
  Future<void>? _running;
  bool _closed = false;
  int _preparing = 0;
  bool busy = false, pausedForPlayback = false;
  int processed = 0;
  String? error;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<T> withPlaybackPriority<T>(Future<T> Function() operation) async {
    _preparing++;
    pausedForPlayback = true;
    _notify();
    try {
      await Future.wait([_probe.cancel(), _access.cancel()]);
      await _running;
      return await operation();
    } finally {
      _preparing--;
    }
  }

  Future<void> setMode(String mode) async {
    await store.setProbeMode(mode);
    if (mode == 'playback') {
      await _probe.cancel();
      await _access.cancel();
    }
    unawaited(tick());
  }

  Future<void> tick() {
    if (_closed || _running != null) return _running ?? Future.value();
    final task = _tick();
    _running = task;
    return task.whenComplete(() => _running = null);
  }

  Future<void> _tick() async {
    try {
      final currentSnapshots = snapshots();
      final activePaths = currentSnapshots.map((s) => s.snapshotPath).toSet();
      _seen.removeWhere((path, _) => !activePaths.contains(path));
      for (final snapshot in currentSnapshots) {
        if (_closed) return;
        final file = File(snapshot.snapshotPath);
        if (!await file.exists()) continue;
        final stamp = (await file.stat()).modified.microsecondsSinceEpoch;
        if (_seen[snapshot.snapshotPath] == stamp) continue;
        final path = relativePathFor(snapshot);
        if (path == null) continue;
        final resource = await store.resourceAt(snapshot.sourceId, path);
        if (resource == null) {
          _seen[snapshot.snapshotPath] = stamp;
          continue;
        }
        Map<String, dynamic> metadata;
        try {
          metadata = Map<String, dynamic>.from(
            jsonDecode(await file.readAsString()),
          );
        } on FormatException {
          continue;
        }
        if (resource.mediaKind != 'iso' && resource.mediaKind != 'bdmv') {
          final reported = metadata['path'];
          if (reported is! String ||
              (resource.sourceKind.name == 'local'
                  ? !p.equals(reported, snapshot.target)
                  : reported != snapshot.target)) {
            continue;
          }
        }
        final info = technicalInfoFromMpv(metadata);
        if ((info['video'] as List).isEmpty) continue;
        _seen[snapshot.snapshotPath] = stamp;
        final previous = await store.probe(resource.id);
        if (previous == null ||
            previous['origin'] != 'MediaInfo' ||
            previous['state'] != 'complete' ||
            resource.mediaKind == 'iso' ||
            resource.mediaKind == 'bdmv') {
          final disc =
              resource.mediaKind == 'iso' || resource.mediaKind == 'bdmv';
          await store.saveProbe(resource.id, {
            ...?previous,
            ...info,
            if (disc) 'fileSize': previous?['fileSize'],
            if (disc) 'programme': metadata['programme'],
            if (disc) 'programmeType': metadata['programmeType'],
          });
        }
      }
      if (_closed || await store.probeMode() != 'full') return;
      pausedForPlayback = _preparing > 0 || await isPlaying();
      _notify();
      if (pausedForPlayback || _closed) return;
      final resource = (await store.unprobedResources(limit: 1)).firstOrNull;
      if (resource == null) return;
      final root = await store.root(resource.rootId);
      if (root == null || _preparing > 0 || _closed) return;
      busy = true;
      error = null;
      _notify();
      try {
        final target = await _access.prepare(resource, sourceFor(root));
        if (_preparing > 0 ||
            await isPlaying() ||
            _closed ||
            await store.probeMode() != 'full') {
          throw const FilmCatalogException('cancelled');
        }
        final metadata = await _probe.probe(
          target.target,
          headers: target.headers,
        );
        if (_preparing > 0 || _closed) {
          throw const FilmCatalogException('cancelled');
        }
        await store.saveProbe(resource.id, {
          ...metadata,
          ...target.metadata,
          'fullProbed': true,
          'fullProbeState': metadata['state'],
        });
        processed++;
      } on FilmCatalogException catch (e) {
        if (e.code == 'probePlaybackOnly' && !_closed) {
          await store.saveProbe(resource.id, {
            'origin': 'MediaInfo',
            'state': 'playbackOnly',
          });
        } else if (e.code != 'cancelled' && _preparing == 0 && !_closed) {
          error = e.code;
          await store.saveProbe(resource.id, {
            'origin': 'MediaInfo',
            'state': 'failed',
            'error': e.code,
            'fullProbed': true,
            'fullProbeState': 'failed',
          });
        }
      } on AppException {
        if (_preparing == 0 && !_closed) {
          error = 'probeFailed';
          await store.saveProbe(resource.id, {
            'origin': 'MediaInfo',
            'state': 'failed',
            'error': error,
            'fullProbed': true,
            'fullProbeState': 'failed',
          });
        }
      } on FileSystemException {
        if (_preparing == 0 && !_closed) {
          error = 'probeFailed';
          await store.saveProbe(resource.id, {
            'origin': 'MediaInfo',
            'state': 'failed',
            'error': error,
            'fullProbed': true,
            'fullProbeState': 'failed',
          });
        }
      } finally {
        await _access.close();
        busy = false;
        _notify();
      }
    } on DatabaseException {
      error = 'catalogStorageFailed';
      _notify();
    } on FileSystemException {
      error = 'probeFailed';
      _notify();
    }
  }

  Future<void> retryFailed() async {
    await store.clearFailedProbes();
    processed = 0;
    error = null;
    unawaited(tick());
  }

  Future<void> close() async {
    stop();
    await _probe.cancel();
    await _access.cancel();
    await _running;
    _seen.clear();
    super.dispose();
  }
}
