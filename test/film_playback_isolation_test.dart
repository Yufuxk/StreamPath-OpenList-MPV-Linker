import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/playback_history.dart';

void main() {
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp('film_isolation_'),
  );
  tearDown(() async => temp.delete(recursive: true));

  test('影视库会话独立持久化，不占用旧会话名额或改写旧文件', () async {
    final browser = PlaybackHistoryStore.forPath(
      p.join(temp.path, 'history.json'),
    );
    final films = browser.forFilmLibrary();
    PlaybackHistory history(String id, PlaybackHistoryKind kind) =>
        PlaybackHistory(
          sessionId: id,
          sourceId: 'source',
          kind: kind,
          dirCrumbs: const [],
          fileName: '$id.mkv',
          videoIndex: 0,
          updatedAt: DateTime.now(),
        );
    expect(
      await browser.upsert(history('browser-1', PlaybackHistoryKind.video)),
      isTrue,
    );
    expect(
      await browser.upsert(history('browser-2', PlaybackHistoryKind.iso)),
      isTrue,
    );
    final baseline = await File(
      p.join(temp.path, 'history.json'),
    ).readAsBytes();
    expect(await films.loadAll(), isEmpty);
    expect(
      await films.upsert(history('film-1', PlaybackHistoryKind.video)),
      isTrue,
    );
    expect(
      await films.upsert(history('film-2', PlaybackHistoryKind.iso)),
      isTrue,
    );
    final reopened = browser.forFilmLibrary();
    expect((await reopened.loadAll()).map((h) => h.sessionId), [
      'film-1',
      'film-2',
    ]);
    await reopened.remove('film-1');
    await reopened.clear();
    expect((await browser.loadAll()).map((h) => h.sessionId), [
      'browser-1',
      'browser-2',
    ]);
    expect(
      await File(p.join(temp.path, 'history.json')).readAsBytes(),
      baseline,
    );
  });

  test('同一文件的影视库与旧媒体中心续播记录、隐藏和删除互相独立', () async {
    final browser = MediaLibraryStore.forPath(
      p.join(temp.path, 'media_library.json'),
    );
    final films = browser.forFilmLibrary();
    const item = MediaLibraryItem(
      sourceId: 'source',
      parentPath: 'Movies',
      name: 'movie.mkv',
      kind: MediaLibraryKind.video,
    );
    await browser.recordPlayback(item, playbackSessionId: 'browser-session');
    final baseline = await File(
      p.join(temp.path, 'media_library.json'),
    ).readAsBytes();
    expect(await films.playbackHistory('source', audio: false), isEmpty);
    await films.recordPlayback(
      item,
      playbackSessionId: 'film-session',
      playlistIndex: 0,
      playlistCount: 1,
    );
    final reopened = browser.forFilmLibrary();
    final film = (await reopened.playbackHistory(
      'source',
      audio: false,
    )).single;
    expect(film.playbackSessionId, 'film-session');
    await reopened.dismissVideoContinueSession('source', 'film-session');
    expect(
      (await reopened.playbackHistory(
        'source',
        audio: false,
      )).single.continueDismissed,
      isTrue,
    );
    await reopened.removePlaybackRecord(film);
    expect(await reopened.playbackHistory('source', audio: false), isEmpty);
    final old = (await browser.playbackHistory('source', audio: false)).single;
    expect(old.playbackSessionId, 'browser-session');
    expect(old.continueDismissed, isFalse);
    expect(
      await File(p.join(temp.path, 'media_library.json')).readAsBytes(),
      baseline,
    );
  });
}
