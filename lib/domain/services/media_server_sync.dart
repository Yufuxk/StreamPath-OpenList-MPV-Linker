import 'dart:async';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/video_queue.dart';
import 'media_server_api.dart';
import 'media_server_source.dart';

/// 离线状态先落库；认证错误暂停提交，重新连接后先提交再拉取。
class MediaServerSync {
  MediaServerSync(
    this.store,
    this.source, {
    this.onUserData,
    this.onErrorChanged,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final Future<void> Function(Map<String, dynamic>)? onUserData;
  final void Function()? onErrorChanged;
  final FilmCatalogStore store;
  final MediaServerSource source;
  final _sessions =
      <String, (ServerPlaybackInfo, VideoProgressUpdate, DateTime)>{};
  Future<void> _tail = Future.value();
  bool _closed = false;
  String? error;
  Future<void> waitForIdle() => _tail;
  Future<void> flushPending() => _enqueue(() => _flush());
  Future<void> _enqueue(Future<void> Function() operation) {
    if (_closed) return Future.value();
    final task = _tail.then((_) => operation());
    _tail = task.catchError((Object cause) {
      if (cause is FilmCatalogException) {
        if (error != cause.code) {
          error = cause.code;
          onErrorChanged?.call();
        }
        return;
      }
      throw cause;
    });
    return _tail;
  }

  Map<String, dynamic> _body(
    ServerPlaybackInfo info,
    VideoProgressUpdate update,
  ) => {
    'ItemId': info.itemId,
    'MediaSourceId': info.mediaSourceId,
    'PlaySessionId': info.playSessionId,
    'PositionTicks': update.positionMs * 10000,
    'IsPaused': update.paused,
    'CanSeek': true,
    'PlayMethod': 'DirectPlay',
  };
  Future<void> progress(VideoProgressUpdate update) => _enqueue(() async {
    final row = await store.serverResource(update.sourceId, update.path);
    if (row == null) return;
    final item = row['item_id'] as String;
    final info = source.reader.playbackInfo(update.path);
    await store.queueServerState(update.sourceId, item, {
      'positionMs': update.positionMs,
      'paused': update.paused,
      if (update.completed) 'watched': true,
    });
    if (info == null) return;
    final now = _now();
    final previous = _sessions[item];
    final immediate =
        update.stopped ||
        update.completed ||
        previous == null ||
        previous.$2.paused != update.paused ||
        (update.positionMs -
                    previous.$2.positionMs -
                    (update.paused
                        ? 0
                        : update.recordedAt
                              .difference(previous.$2.recordedAt)
                              .inMilliseconds))
                .abs() >
            3000;
    if (!immediate &&
        now.difference(previous.$3) < const Duration(seconds: 10)) {
      _sessions[item] = (info, update, previous.$3);
      return;
    }
    final reported = <String>{item};
    if (previous == null) {
      for (final active in _sessions.values) {
        await source.api.report('stop', _body(active.$1, active.$2));
        reported.add(active.$1.itemId);
      }
      _sessions.clear();
      await source.api.report('start', _body(info, update));
    }
    await source.api.report(
      update.stopped || update.completed ? 'stop' : 'progress',
      _body(info, update),
    );
    _sessions[item] = (info, update, now);
    if (update.stopped || update.completed) {
      _sessions.remove(item);
      source.reader.releasePlayback(update.path);
    }
    await _flush(reported: reported);
  });
  Future<void> watched(List<FilmResource> resources, bool value) =>
      _enqueue(() async {
        for (final resource in resources) {
          final row = await store.serverResource(
            resource.sourceId,
            resource.path,
          );
          if (row != null) {
            await store.queueServerState(
              resource.sourceId,
              row['item_id'] as String,
              {'watched': value, 'positionMs': 0},
            );
          }
        }
        await _flush();
      });
  Future<void> _flush({Set<String> reported = const {}}) async {
    for (final pending in await store.pendingServerStates(
      source.api.config.id,
    )) {
      final id = pending['itemId'] as String;
      final state = Map<String, dynamic>.from(pending['state'] as Map);
      if (_sessions.containsKey(id) && !reported.contains(id)) continue;
      if (state['watched'] case final bool watched) {
        await source.api.played(id, watched);
      }
      if (state['favorite'] case final bool favorite) {
        await source.api.favorite(id, favorite);
      }
      if (state['positionMs'] case final int position
          when !_sessions.containsKey(id) && !reported.contains(id)) {
        await source.api.report('stop', {
          'ItemId': id,
          'PositionTicks': position * 10000,
          'IsPaused': state['paused'] == true,
          'PlayMethod': 'DirectPlay',
        });
      }
      await store.acknowledgeServerState(source.api.config.id, id, state);
    }
    if (error != null) {
      error = null;
      onErrorChanged?.call();
    }
  }

  Future<void> refresh() => _enqueue(() async {
    await _flush();
    await for (final page in source.api.items(types: 'Movie,Episode')) {
      await store.withBatchedChanges(() async {
        for (final item in page) {
          if (_closed) return;
          if (_sessions.containsKey(item['Id'])) continue;
          final applied = await store.applyServerUserData(
            source.api.config.id,
            item['Id'] as String,
            Map<String, dynamic>.from(item['UserData'] as Map? ?? {}),
          );
          if (applied) await onUserData?.call(item);
        }
      });
    }
  });
  Future<void> close() async {
    _closed = true;
    await _tail;
  }
}
