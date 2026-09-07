import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/models/media_library_config.dart';
import 'package:streampath/data/models/media_library_item.dart';

class _FailOnceReadFile implements File {
  _FailOnceReadFile(this._delegate);

  final File _delegate;
  bool _shouldFail = true;

  @override
  String get path => _delegate.path;

  @override
  Directory get parent => _delegate.parent;

  @override
  Future<bool> exists() => _delegate.exists();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    if (_takeFailure()) {
      return Future<String>.error(FileSystemException('模拟瞬时读取失败', path));
    }
    return _delegate.readAsString(encoding: encoding);
  }

  @override
  Future<Uint8List> readAsBytes() {
    if (_takeFailure()) {
      return Future<Uint8List>.error(FileSystemException('模拟瞬时读取失败', path));
    }
    return _delegate.readAsBytes();
  }

  bool _takeFailure() {
    if (!_shouldFail) return false;
    _shouldFail = false;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tempDir;
  late File libraryFile;
  late DateTime now;
  late MediaLibraryStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('media_library_');
    libraryFile = File(p.join(tempDir.path, 'media_library.json'));
    now = DateTime.utc(2026, 8, 19);
    store = MediaLibraryStore.forPath(libraryFile.path, now: () => now);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  MediaLibraryItem item(
    String name, {
    String sourceId = 'source-a',
    MediaLibraryKind kind = MediaLibraryKind.video,
    String parentPath = '影视/电影',
  }) => MediaLibraryItem(
    sourceId: sourceId,
    parentPath: parentPath,
    name: name,
    kind: kind,
  );

  List<File> corruptBackups([File? source]) => (source?.parent ?? tempDir)
      .listSync(followLinks: false)
      .whereType<File>()
      .where(
        (file) =>
            p
                .basename(file.path)
                .startsWith(
                  '${p.basename(source?.path ?? libraryFile.path)}.corrupt-',
                ) &&
            file.path.endsWith('.bak'),
      )
      .toList();

  Map<String, dynamic> libraryDocument({
    int version = 1,
    Object favorites = const <Object>[],
    Object recentDirectories = const <Object>[],
    Object videoHistory = const <Object>[],
    Object audioHistory = const <Object>[],
    Object? isoHistory,
  }) => <String, dynamic>{
    'version': version,
    'favorites': favorites,
    'recentDirectories': recentDirectories,
    'videoHistory': videoHistory,
    'audioHistory': audioHistory,
    'isoHistory': ?isoHistory,
  };

  test('收藏可切换、按来源隔离并在重启后恢复', () async {
    expect(await store.toggleFavorite(item('A.mkv')), isTrue);
    expect(
      await store.toggleFavorite(item('B.flac', kind: MediaLibraryKind.audio)),
      isTrue,
    );
    expect(
      await store.toggleFavorite(item('C.mkv', sourceId: 'source-b')),
      isTrue,
    );
    expect(await store.favorites('source-a'), hasLength(2));
    expect(await store.favorites('source-b'), hasLength(1));

    final reloaded = MediaLibraryStore.forPath(libraryFile.path);
    expect(
      (await reloaded.favorites('source-a')).map((record) => record.item.name),
      containsAll(['A.mkv', 'B.flac']),
    );
    expect(File('${libraryFile.path}.tmp').existsSync(), isFalse);

    expect(await reloaded.toggleFavorite(item('A.mkv')), isFalse);
    expect(
      (await reloaded.favorites('source-a')).map((record) => record.item.name),
      isNot(contains('A.mkv')),
    );
  });

  test('最近目录去重、更新时间并限制每个来源的容量', () async {
    final records = <Map<String, dynamic>>[];
    for (
      var index = 0;
      index < MediaLibraryStore.maxRecentDirectories;
      index++
    ) {
      records.add(
        MediaLibraryRecord(
          item: item(
            '目录$index',
            kind: MediaLibraryKind.directory,
            parentPath: '影视',
          ),
          updatedAt: now.subtract(Duration(minutes: index + 1)),
        ).toJson(),
      );
    }
    libraryFile.writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'version': 1,
        'favorites': const [],
        'recentDirectories': records,
        'videoHistory': const [],
        'audioHistory': const [],
      }),
    );
    store = MediaLibraryStore.forPath(libraryFile.path, now: () => now);

    await store.recordRecentDirectory(
      item('新目录', kind: MediaLibraryKind.directory, parentPath: '影视'),
    );
    final recent = await store.recentDirectories('source-a');
    expect(recent, hasLength(MediaLibraryStore.maxRecentDirectories));
    expect(recent.first.item.name, '新目录');
    expect(recent.map((record) => record.item.name), isNot(contains('目录99')));

    now = now.add(const Duration(minutes: 1));
    await store.recordRecentDirectory(
      item('目录0', kind: MediaLibraryKind.directory, parentPath: '影视'),
    );
    expect((await store.recentDirectories('source-a')).first.item.name, '目录0');
  });

  test('视频和音频长期历史独立去重且删除只影响 UI 记录', () async {
    final video = item('A.mkv');
    final audio = item('A.flac', kind: MediaLibraryKind.audio);
    await store.recordPlayback(video);
    await store.recordPlayback(audio);
    now = now.add(const Duration(minutes: 1));
    await store.recordPlayback(video);

    expect(await store.playbackHistory('source-a', audio: false), hasLength(1));
    expect(await store.playbackHistory('source-a', audio: true), hasLength(1));

    await store.removePlayback(video);
    expect(await store.playbackHistory('source-a', audio: false), isEmpty);
    expect(await store.playbackHistory('source-a', audio: true), hasLength(1));
  });

  test('ISO 最近播放使用独立分栏并在重启后恢复', () async {
    final iso = item('DISC.iso', kind: MediaLibraryKind.iso);
    await store.recordPlayback(iso, playbackSessionId: 'iso-session');

    expect(await store.playbackHistory('source-a', audio: false), isEmpty);
    expect(await store.playbackHistory('source-a', audio: true), isEmpty);
    final isoHistory = await store.playbackHistory(
      'source-a',
      audio: false,
      iso: true,
    );
    expect(isoHistory.single.item, same(iso));
    expect(isoHistory.single.playbackSessionId, 'iso-session');

    final reloaded = MediaLibraryStore.forPath(libraryFile.path);
    final restored = await reloaded.playbackHistory(
      'source-a',
      audio: false,
      iso: true,
    );
    expect(restored.single.item.kind, MediaLibraryKind.iso);
    expect((jsonDecode(libraryFile.readAsStringSync()) as Map)['version'], 2);
  });

  test('本地 ISO 播放会话持久化来源快照和进程身份', () async {
    final iso = item('本地盘.iso', kind: MediaLibraryKind.iso);
    final modified = DateTime(2026, 9, 1, 12);
    final snapshot = LocalDiscSessionSnapshot(
      rootId: 'root-1',
      relativePath: '电影/本地盘.iso',
      size: 2048,
      modified: modified,
      fingerprint: 'fingerprint',
      playerPid: 1234,
      playerExecutablePath: r'C:\Players\mpv.exe',
      playerCreationTime: 987654,
    );

    await store.recordPlayback(
      iso,
      playbackSessionId: 'local-disc-session',
      localDiscSession: snapshot,
    );
    expect(
      await store.updateLocalDiscTitleContext(
        sourceId: 'source-a',
        playbackSessionId: 'local-disc-session',
        currentEdition: 2,
        editionCount: 4,
      ),
      isTrue,
    );

    final reloaded = MediaLibraryStore.forPath(libraryFile.path);
    final restored = await reloaded.playbackHistory(
      'source-a',
      audio: false,
      iso: true,
    );
    expect(restored.single.localDiscSession?.rootId, 'root-1');
    expect(restored.single.localDiscSession?.relativePath, '电影/本地盘.iso');
    expect(restored.single.localDiscSession?.size, 2048);
    expect(restored.single.localDiscSession?.modified, modified);
    expect(restored.single.localDiscSession?.fingerprint, 'fingerprint');
    expect(restored.single.localDiscSession?.playerPid, 1234);
    expect(
      restored.single.localDiscSession?.playerExecutablePath,
      r'C:\Players\mpv.exe',
    );
    expect(restored.single.localDiscSession?.playerCreationTime, 987654);
    expect(restored.single.localDiscSession?.currentEdition, 2);
    expect(restored.single.localDiscSession?.editionCount, 4);
  });

  test('同一播放会话切集只更新原记录且不同会话分别保留', () async {
    await store.recordPlayback(
      item('第一集.mkv'),
      playbackSessionId: 'playlist-1',
    );
    now = now.add(const Duration(minutes: 1));
    await store.recordPlayback(
      item('第二集.mkv'),
      playbackSessionId: 'playlist-1',
    );

    var history = await store.playbackHistory('source-a', audio: false);
    expect(history, hasLength(1));
    expect(history.single.item.name, '第二集.mkv');
    expect(history.single.playbackSessionId, 'playlist-1');

    now = now.add(const Duration(minutes: 1));
    await store.recordPlayback(
      item('第二集.mkv'),
      playbackSessionId: 'playlist-2',
    );
    history = await store.playbackHistory('source-a', audio: false);
    expect(history, hasLength(2));
    expect(history.map((record) => record.playbackSessionId), [
      'playlist-2',
      'playlist-1',
    ]);
    expect(history[0].recordKey, isNot(history[1].recordKey));

    await store.recordPlayback(
      item('第一首.flac', kind: MediaLibraryKind.audio),
      playbackSessionId: 'playlist-1',
    );
    await store.recordPlayback(
      item('第二首.flac', kind: MediaLibraryKind.audio),
      playbackSessionId: 'playlist-1',
    );
    final audioHistory = await store.playbackHistory('source-a', audio: true);
    expect(audioHistory, hasLength(1));
    expect(audioHistory.single.item.name, '第二首.flac');
  });

  test('删除一批播放记录不影响同一文件的其他会话', () async {
    final video = item('同一集.mkv');
    await store.recordPlayback(video, playbackSessionId: 'playlist-1');
    now = now.add(const Duration(minutes: 1));
    await store.recordPlayback(video, playbackSessionId: 'playlist-2');

    final history = await store.playbackHistory('source-a', audio: false);
    await store.removePlaybackRecord(
      history.singleWhere((record) => record.playbackSessionId == 'playlist-1'),
    );

    final remaining = await store.playbackHistory('source-a', audio: false);
    expect(remaining, hasLength(1));
    expect(remaining.single.playbackSessionId, 'playlist-2');
  });

  test('旧版无播放会话字段的历史仍可读取', () async {
    libraryFile.writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'version': 1,
        'favorites': const [],
        'recentDirectories': const [],
        'videoHistory': [
          MediaLibraryRecord(item: item('旧记录.mkv'), updatedAt: now).toJson(),
        ],
        'audioHistory': const [],
      }),
    );
    store = MediaLibraryStore.forPath(libraryFile.path, now: () => now);

    final history = await store.playbackHistory('source-a', audio: false);
    expect(history, hasLength(1));
    expect(history.single.item.name, '旧记录.mkv');
    expect(history.single.playbackSessionId, isNull);
  });

  test('个人资产写入成功后通知已打开的界面', () async {
    var changes = 0;
    void listener() => changes++;
    store.addListener(listener);

    final video = item('通知影片.mkv');
    await store.recordPlayback(video);
    await store.toggleFavorite(video);
    await store.removePlayback(video);

    expect(changes, 3);
    store.removeListener(listener);
    await store.recordPlayback(video);
    expect(changes, 3);
  });

  test('视频长期历史按来源限制容量并淘汰最旧记录', () async {
    final records = List.generate(
      MediaLibraryStore.maxPlaybackHistoryPerLane,
      (index) => MediaLibraryRecord(
        item: item('影片$index.mkv'),
        updatedAt: now.subtract(Duration(minutes: index + 1)),
      ).toJson(),
    );
    libraryFile.writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'version': 1,
        'favorites': const [],
        'recentDirectories': const [],
        'videoHistory': records,
        'audioHistory': const [],
      }),
    );
    store = MediaLibraryStore.forPath(libraryFile.path, now: () => now);

    await store.recordPlayback(item('新影片.mkv'));
    final history = await store.playbackHistory('source-a', audio: false);
    expect(history, hasLength(MediaLibraryStore.maxPlaybackHistoryPerLane));
    expect(history.first.item.name, '新影片.mkv');
    expect(
      history.map((record) => record.item.name),
      isNot(contains('影片499.mkv')),
    );
  });

  test('统一容量配置立即按来源裁剪并约束后续写入', () async {
    for (var index = 0; index < 4; index++) {
      await store.toggleFavorite(item('收藏$index.mkv'));
      await store.recordRecentDirectory(
        item('目录$index', kind: MediaLibraryKind.directory, parentPath: '影视'),
      );
      await store.recordPlayback(
        item('影片$index.mkv'),
        playbackSessionId: 'session-$index',
      );
    }
    await store.toggleFavorite(item('其他来源.mkv', sourceId: 'source-b'));

    await store.applyConfig(
      const MediaLibraryConfig(
        maxFavoritesPerSource: 2,
        maxContinuePerLane: 1,
        maxRecentPlaybackPerLane: 2,
        maxRecentDirectoriesPerSource: 2,
      ),
    );

    expect(await store.favorites('source-a'), hasLength(2));
    expect(await store.favorites('source-b'), hasLength(1));
    expect(await store.recentDirectories('source-a'), hasLength(2));
    expect(await store.playbackHistory('source-a', audio: false), hasLength(2));

    await store.recordPlayback(
      item('新影片.mkv'),
      playbackSessionId: 'session-new',
    );
    final history = await store.playbackHistory('source-a', audio: false);
    expect(history, hasLength(2));
    expect(history.first.item.name, '新影片.mkv');
  });

  test('分项清理互不越界且清空继续播放不删除真实历史', () async {
    final favorite = item('收藏.mkv');
    final directory = item(
      '最近目录',
      kind: MediaLibraryKind.directory,
      parentPath: '影视',
    );
    await store.toggleFavorite(favorite);
    await store.recordRecentDirectory(directory);
    await store.recordPlayback(item('第一集.mkv'), playbackSessionId: 'session-1');
    await store.recordPlayback(
      item('其他来源.mkv', sourceId: 'source-b'),
      playbackSessionId: 'session-b',
    );

    await store.clearContinuePlayback('source-a');
    var history = await store.playbackHistory('source-a', audio: false);
    expect(history, hasLength(1));
    expect(history.single.continueDismissed, isTrue);

    await store.recordPlayback(item('第二集.mkv'), playbackSessionId: 'session-1');
    history = await store.playbackHistory('source-a', audio: false);
    expect(history.single.item.name, '第二集.mkv');
    expect(history.single.continueDismissed, isFalse);

    await store.clearFavorites('source-a');
    await store.clearRecentDirectories('source-a');
    await store.clearAllPlaybackHistory('source-a');
    expect(await store.favorites('source-a'), isEmpty);
    expect(await store.recentDirectories('source-a'), isEmpty);
    expect(await store.playbackHistory('source-a', audio: false), isEmpty);
    expect(await store.playbackHistory('source-b', audio: false), hasLength(1));
  });

  test('损坏文件不阻止加载且不在读取阶段被删除', () async {
    libraryFile.writeAsStringSync('{broken');
    await store.load();

    expect(await store.favorites('source-a'), isEmpty);
    expect(libraryFile.readAsStringSync(), '{broken');
  });

  test('格式损坏后首次写入先生成唯一精确备份', () async {
    final original = utf8.encode('{broken');
    libraryFile.writeAsBytesSync(original);
    await store.load();

    expect(await store.toggleFavorite(item('新收藏.mkv')), isTrue);

    final backups = corruptBackups();
    expect(backups, hasLength(1));
    expect(backups.single.readAsBytesSync(), original);
    expect(await store.favorites('source-a'), hasLength(1));

    await store.recordPlayback(item('新播放.mkv'));
    expect(corruptBackups(), hasLength(1));

    final secondOriginal = utf8.encode('{broken-again');
    libraryFile.writeAsBytesSync(secondOriginal);
    store = MediaLibraryStore.forPath(libraryFile.path, now: () => now);
    expect(await store.toggleFavorite(item('第二次收藏.mkv')), isTrue);

    final allBackups = corruptBackups();
    expect(allBackups, hasLength(2));
    expect(
      allBackups.map((file) => file.readAsBytesSync()),
      containsAll(<List<int>>[original, secondOriginal]),
    );
  });

  test('四类个人资产 mutation 都不会直接覆盖格式损坏文件', () async {
    final cases = <String, Future<void> Function(MediaLibraryStore)>{
      'favorites': (target) async {
        await target.toggleFavorite(item('收藏.mkv'));
      },
      'recentDirectories': (target) => target.recordRecentDirectory(
        item('目录', kind: MediaLibraryKind.directory),
      ),
      'videoHistory': (target) => target.recordPlayback(item('视频.mkv')),
      'audioHistory': (target) =>
          target.recordPlayback(item('音频.flac', kind: MediaLibraryKind.audio)),
    };

    for (final entry in cases.entries) {
      final targetFile = File(
        p.join(tempDir.path, entry.key, 'media_library.json'),
      );
      targetFile.parent.createSync(recursive: true);
      final original = utf8.encode('{broken-${entry.key}');
      targetFile.writeAsBytesSync(original);
      final targetStore = MediaLibraryStore.forPath(
        targetFile.path,
        now: () => now,
      );
      await targetStore.load();

      await entry.value(targetStore);

      final backups = corruptBackups(targetFile);
      expect(backups, hasLength(1), reason: entry.key);
      expect(backups.single.readAsBytesSync(), original, reason: entry.key);
    }
  });

  test('结构损坏与单条坏记录在重写前保留原始文件', () async {
    final validRecord = MediaLibraryRecord(
      item: item('原收藏.mkv'),
      updatedAt: now,
    ).toJson();
    final original = utf8.encode(
      jsonEncode(
        libraryDocument(
          favorites: <Object>[
            validRecord,
            <String, Object>{'broken': true},
          ],
          recentDirectories: const <String, Object>{'broken': true},
        ),
      ),
    );
    libraryFile.writeAsBytesSync(original);
    store = MediaLibraryStore.forPath(libraryFile.path, now: () => now);

    expect(await store.favorites('source-a'), hasLength(1));
    expect(await store.toggleFavorite(item('新收藏.mkv')), isTrue);

    final backups = corruptBackups();
    expect(backups, hasLength(1));
    expect(backups.single.readAsBytesSync(), original);
    expect(
      (await store.favorites('source-a')).map((record) => record.item.name),
      containsAll(<String>['原收藏.mkv', '新收藏.mkv']),
    );
  });

  test('未来版本只读加载且禁止降级覆盖', () async {
    final original = utf8.encode(
      jsonEncode(
        libraryDocument(
          version: 3,
          favorites: <Object>[
            MediaLibraryRecord(item: item('未来收藏.mkv'), updatedAt: now).toJson(),
          ],
        ),
      ),
    );
    libraryFile.writeAsBytesSync(original);
    store = MediaLibraryStore.forPath(libraryFile.path, now: () => now);
    var changes = 0;
    store.addListener(() => changes++);

    expect(await store.favorites('source-a'), hasLength(1));
    await expectLater(
      store.toggleFavorite(item('禁止写入.mkv')),
      throwsA(isA<FileSystemException>()),
    );

    expect(libraryFile.readAsBytesSync(), original);
    expect(File('${libraryFile.path}.tmp').existsSync(), isFalse);
    expect(corruptBackups(), isEmpty);
    expect(changes, 0);
  });

  test('瞬时读取失败后本进程保持只读且不覆盖恢复可读的原文件', () async {
    final original = utf8.encode(jsonEncode(libraryDocument()));
    libraryFile.writeAsBytesSync(original);
    final failingFile = _FailOnceReadFile(libraryFile);
    store = IOOverrides.runZoned(
      () => MediaLibraryStore.forPath(libraryFile.path, now: () => now),
      createFile: (_) => failingFile,
    );
    var changes = 0;
    store.addListener(() => changes++);

    await store.load();
    expect(libraryFile.readAsBytesSync(), original);
    await expectLater(
      store.recordPlayback(item('禁止覆盖.mkv')),
      throwsA(isA<FileSystemException>()),
    );

    expect(libraryFile.readAsBytesSync(), original);
    expect(File('${libraryFile.path}.tmp').existsSync(), isFalse);
    expect(corruptBackups(), isEmpty);
    expect(changes, 0);
  });

  test('来源标识忽略凭据、查询参数和尾斜杠', () {
    final first = mediaSourceId(
      baseUrl: 'HTTP://user:secret@Example.COM:80/dav/?token=signed#part',
      username: 'alice',
    );
    final second = mediaSourceId(
      baseUrl: 'http://example.com:80/dav',
      username: 'alice',
    );
    final otherUser = mediaSourceId(
      baseUrl: 'http://example.com:80/dav',
      username: 'Alice',
    );

    expect(first, second);
    expect(first, startsWith('sha256:'));
    expect(otherUser, isNot(first));
    expect(first, isNot(contains('secret')));
    expect(first, isNot(contains('token')));
  });
}
