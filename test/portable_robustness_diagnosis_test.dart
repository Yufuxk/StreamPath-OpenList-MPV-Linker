import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/player_process_controller.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/widgets/adaptive_film_backdrop.dart';
import 'package:streampath/presentation/widgets/film_artwork_picker.dart';

class _NoCredentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}

class _PickerCatalog extends FilmCatalogController {
  _PickerCatalog({
    required super.store,
    required super.tmdb,
    required super.images,
    required super.sourceFor,
  });

  // 图片选择器的落盘验证不加载无关的首页栏目。
  @override
  Future<void> refresh({bool more = false, bool home = true}) async {
    final path = await store.backgroundPath();
    backgroundFile = path == null || path.isEmpty ? null : File(path);
  }
}

// 会话与背景恢复回归；条件性补充项仍明确标注已知边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(Directory, ExternalPlayerService, String, File)> recoveryFixture({
    PlayerProcessController? controller,
  }) async {
    final temp = await Directory.systemTemp.createTemp(
      'sp_recovery_diagnosis_',
    );
    final cache = await AppPaths.cacheDirectory();
    expect(
      p.equals(
        cache.path,
        p.join(Directory.current.path, 'stream_path_data', 'cache'),
      ),
      isFalse,
    );
    final id = 'diagnosis-${DateTime.now().microsecondsSinceEpoch}';
    final entries = File(p.join(cache.path, 'mpv-season-entries-$id.json'));
    final service = ExternalPlayerService(
      configStore: StreamPathConfigStore.forPath(
        p.join(temp.path, 'config.json'),
      ),
      processController: controller,
    );
    addTearDown(() async {
      service.releaseSession(id);
      if (await entries.exists()) await entries.delete();
      await temp.delete(recursive: true);
    });
    return (temp, service, id, entries);
  }

  test('缺失队列只标记当前会话，修复工件后可重新恢复', () async {
    final (temp, service, id, entries) = await recoveryFixture();
    final queue = File(p.join(temp.path, 'queue.json'));
    await entries.writeAsString(
      jsonEncode({'entries': [], 'queueFile': queue.path}),
    );
    await service.restoreSession(sessionId: id, pid: null);
    expect(service.hasRestoreFailure(id), isTrue);
    expect(await service.isPlayerRunning(id), isFalse);
    await queue.writeAsString(jsonEncode({'version': 1}));
    service.releaseSession(id);
    await service.restoreSession(sessionId: id, pid: null);
    expect(service.hasRestoreFailure(id), isFalse);
    expect(await service.isPlayerRunning(id), isFalse);
  });

  test('截断的会话 JSON 不阻断恢复，完整 JSON 正常恢复', () async {
    final (_, service, id, entries) = await recoveryFixture();
    await entries.writeAsString('{"entries":[');
    await service.restoreSession(sessionId: id, pid: null);
    expect(service.hasRestoreFailure(id), isTrue);
    await entries.writeAsString(jsonEncode({'entries': []}));
    service.releaseSession(id);
    await service.restoreSession(sessionId: id, pid: null);
    expect(service.hasRestoreFailure(id), isFalse);
    expect(await service.isPlayerRunning(id), isFalse);
  });

  test('旧记录缺身份时可确认 PID 已不存在，刷新保持退出状态', () async {
    var lookups = 0;
    final controller = PlayerProcessController(
      snapshotLoader: (_) async {
        lookups++;
        return const PlayerProcessLookupResult.notFound();
      },
    );
    final (_, service, id, _) = await recoveryFixture(controller: controller);
    await service.restoreSession(sessionId: id, pid: 2147483640);
    expect(await service.isPlayerRunning(id), isFalse);
    await service.refreshPlaybackStatus(id);
    expect(await service.isPlayerRunning(id), isFalse);
    expect(lookups, 1);
    service.releaseSession(id);
    await service.restoreSession(
      sessionId: id,
      pid: 2147483640,
      executablePath: r'C:\fixtures\mpv.exe',
      creationTime: 1,
    );
    expect(await service.isPlayerRunning(id), isFalse);
    expect(lookups, 2);
  });

  for (final bad in <Object>[
    [],
    {'entries': 'invalid'},
    {
      'entries': [
        {'url': 1},
      ],
    },
    {
      'entries': [
        {'url': 'fixture://one', 'title': 1},
      ],
    },
    {
      'artifacts': [1],
    },
    {'queueFile': 1},
    {'queueGeneration': 'invalid'},
    {'stageNumber': []},
    {'externalAudioInjectionEnabled': 'invalid'},
  ]) {
    test('工件结构错误只隔离当前会话：${jsonEncode(bad)}', () async {
      final (_, service, id, entries) = await recoveryFixture();
      await entries.writeAsString(jsonEncode(bad));
      await service.restoreSession(sessionId: id, pid: null);
      expect(service.hasRestoreFailure(id), isTrue);
      final other = '$id-other';
      await service.restoreSession(sessionId: other, pid: null);
      expect(service.hasRestoreFailure(other), isFalse);
      expect(await service.isPlayerRunning(other), isFalse);
      service.releaseSession(other);
      expect(jsonDecode(await entries.readAsString()), bad);
    });
  }

  for (final bad in <Object>[
    [],
    {'version': 2, 'entries': []},
    {
      'version': 2,
      'generation': 1,
      'serial': 1,
      'entries': [1],
    },
    {
      'version': 2,
      'generation': 1,
      'serial': 1,
      'entries': [
        {'index': 'invalid'},
      ],
    },
  ]) {
    test('滚动队列结构错误不产生 TypeError：${jsonEncode(bad)}', () async {
      final (temp, service, id, entries) = await recoveryFixture();
      final queue = File(p.join(temp.path, 'queue.json'));
      await queue.writeAsString(jsonEncode(bad));
      await entries.writeAsString(
        jsonEncode({'entries': [], 'queueFile': queue.path}),
      );
      await service.restoreSession(sessionId: id, pid: null);
      expect(service.hasRestoreFailure(id), isTrue);
      expect(await queue.exists(), isTrue);
    });
  }

  for (final owned in [true, false]) {
    test('坏工件仍保留${owned ? '存活' : '身份未知'}进程的追踪且不终止进程', () async {
      var terminated = false;
      final identity = PlayerProcessIdentity(
        pid: 22222,
        executablePath: r'C:\fixtures\mpv.exe',
        creationTime: 1,
      );
      final controller = PlayerProcessController(
        snapshotLoader: (_) async => PlayerProcessLookupResult.found(identity),
        processTreeTerminator: (_) async {
          terminated = true;
          return true;
        },
      );
      final (_, service, id, entries) = await recoveryFixture(
        controller: controller,
      );
      await entries.writeAsString('{');
      await service.restoreSession(
        sessionId: id,
        pid: identity.pid,
        executablePath: owned ? identity.executablePath : null,
        creationTime: owned ? identity.creationTime : null,
      );
      expect(service.hasRestoreFailure(id), isTrue);
      expect(await service.isPlayerRunning(id), isTrue);
      expect(await service.isSessionStateUnknown(id), !owned);
      await service.refreshPlaybackStatus(id);
      expect(await service.isPlayerRunning(id), isTrue);
      expect(terminated, isFalse);
      expect(await entries.readAsString(), '{');
    });
  }

  test('已知边界：播放初始化失败被记忆，磁盘恢复后同实例仍失败', () async {
    final temp = await Directory.systemTemp.createTemp('sp_init_diagnosis_');
    final progress = await PlaybackProgressService.open(
      p.join(temp.path, 'progress.db'),
    );
    final config = StreamPathConfigStore.forPath(
      p.join(temp.path, 'config.json'),
    );
    final history = PlaybackHistoryStore.forPath(
      p.join(temp.path, 'history.json'),
    );
    final damaged = File(p.join(temp.path, 'film_streampath.db'));
    await damaged.writeAsString('not a sqlite database');
    final app = AppState(
      configStore: config,
      playbackHistoryStore: history,
      progressService: progress,
    );
    final first = app.initializeFilmPlayback();
    await expectLater(first, throwsA(isA<AppException>()));
    await damaged.delete();
    final valid = await PlaybackProgressService.open(damaged.path);
    await valid.close();
    final second = app.initializeFilmPlayback();
    expect(identical(first, second), isTrue);
    await expectLater(second, throwsA(isA<AppException>()));
    app.dispose();
    final restarted = AppState(
      configStore: config,
      playbackHistoryStore: history,
      progressService: progress,
    );
    await restarted.initializeFilmPlayback();
    restarted.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await progress.close();
    await temp.delete(recursive: true);
  });

  Future<(Directory, FilmCatalogController, File)> backgroundFixture(
    WidgetTester tester,
  ) async {
    return (await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp(
        'sp_background_diagnosis_',
      );
      final store = await FilmCatalogStore.open(
        p.join(temp.path, 'library', 'catalog.db'),
      );
      final tmdb = TmdbMetadataService(credentials: _NoCredentials());
      final cache = FilmCatalogImageCache(
        Directory(p.join(temp.path, 'cache', 'film_artwork')),
        tmdb,
      );
      await cache.directory.create(recursive: true);
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.teal, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, 36);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final file = File(
        p.join(
          cache.directory.path,
          '${FilmCatalogImageCache.cacheKey('/fixture.png', 'original')}.img',
        ),
      );
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      final id = await store.addRoot(
        sourceId: 'fixture',
        kind: MediaSourceKind.local,
        path: 'Movies',
        type: FilmMediaType.movie,
        name: 'Fixture',
      );
      final root = (await store.root(id))!;
      final generation = await store.beginScan(id);
      await store.stage(root, generation, [
        const FilmScanEntry(
          path: 'Movies/a.mkv',
          parentPath: 'Movies',
          name: 'a.mkv',
          mediaKind: 'video',
        ),
      ]);
      await store.commitScan(id, generation, cancelled: () => false);
      await store.bind(
        await store.resources(),
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 1,
          title: 'Fixture',
          originalTitle: 'Fixture',
          overview: '',
          language: 'en',
          backdropPath: '/fixture.png',
        ),
      );
      final catalog = _PickerCatalog(
        store: store,
        tmdb: tmdb,
        images: cache,
        sourceFor: (_) => throw StateError('Unexpected source access'),
      );
      return (temp, catalog, file);
    }))!;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('对照：从缓存选背景会保存持久副本，删除缓存原图不删除副本', (tester) async {
    final (temp, catalog, source) = await backgroundFixture(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await catalog.close();
        await temp.delete(recursive: true);
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFilmArtworkPicker(context, catalog),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await settle(tester);
    await tester.runAsync(() => tester.tap(find.text('Fixture')));
    await settle(tester);
    final saved = catalog.backgroundFile?.path;
    expect(saved, isNotNull);
    expect(saved, isNot(source.path));
    expect(p.basename(p.dirname(saved!)), 'film_custom_artwork');
    await tester.runAsync(() async {
      final bytes = await File(saved).readAsBytes();
      expect(bytes, await source.readAsBytes());
      await source.delete();
      expect(await source.exists(), isFalse);
      expect(await File(saved).readAsBytes(), bytes);
      await catalog.refresh();
      expect(catalog.backgroundFile!.path, saved);
    });
  });

  testWidgets('来源视图的显式重载同步到全局背景宿主', (tester) async {
    final (temp, catalog, _) = await backgroundFixture(tester);
    final scoped = catalog.forSource('fixture');
    var notified = 0;
    catalog.addListener(() => notified++);
    scoped.reloadBackground();
    expect(catalog.backgroundRevision, 1);
    expect(scoped.backgroundRevision, 1);
    expect(notified, 1);
    await tester.runAsync(() async {
      await scoped.close();
      await catalog.close();
      await temp.delete(recursive: true);
    });
  });

  testWidgets('同路径背景恢复后显式重载即可显示，重载失败保留有效帧', (tester) async {
    final (temp, catalog, source) = await backgroundFixture(tester);
    final missing = File(p.join(temp.path, 'restored.png'));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await catalog.close();
        await temp.delete(recursive: true);
      });
    });
    var revision = 0;
    Widget host() => MaterialApp(
      home: AdaptiveFilmBackdrop(
        cache: catalog.images,
        file: missing,
        revision: revision,
      ),
    );
    await tester.pumpWidget(host());
    await settle(tester);
    expect(find.byKey(const Key('adaptive-backdrop-sharp')), findsNothing);
    await tester.runAsync(() => source.copy(missing.path));
    await tester.pumpWidget(host());
    await settle(tester);
    expect(find.byKey(const Key('adaptive-backdrop-sharp')), findsNothing);
    revision++;
    await tester.pumpWidget(host());
    await settle(tester);
    expect(find.byKey(const Key('adaptive-backdrop-sharp')), findsOneWidget);
    final displayed = tester
        .widget<RawImage>(find.byKey(const Key('adaptive-backdrop-sharp')))
        .image;
    await tester.runAsync(() => missing.writeAsString('damaged image'));
    revision++;
    await tester.pumpWidget(host());
    await settle(tester);
    expect(
      identical(
        tester
            .widget<RawImage>(find.byKey(const Key('adaptive-backdrop-sharp')))
            .image,
        displayed,
      ),
      isTrue,
    );
  });

  testWidgets('重新选择同一原图可原子替换损坏背景副本', (tester) async {
    final (temp, catalog, source) = await backgroundFixture(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await catalog.close();
        await temp.delete(recursive: true);
      });
    });
    final damaged = (await tester.runAsync(() async {
      final bytes = await source.readAsBytes();
      final file = File(
        p.join(
          p.dirname(catalog.store.path),
          'film_custom_artwork',
          '${sha256.convert(bytes)}.img',
        ),
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('truncated image');
      return file;
    }))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFilmArtworkPicker(context, catalog),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await settle(tester);
    await tester.runAsync(() => tester.tap(find.text('Fixture')));
    await settle(tester);
    expect(catalog.backgroundFile?.path, damaged.path);
    await tester.runAsync(() async {
      expect(await damaged.readAsBytes(), await source.readAsBytes());
      await FilmCatalogImageCache.validatePortableImage(damaged);
      expect(await File('${damaged.path}.tmp').exists(), isFalse);
    });
    expect(catalog.backgroundRevision, 1);
  });

  testWidgets('背景提交失败时保留旧偏好和旧图片并清理临时文件', (tester) async {
    final (temp, catalog, source) = await backgroundFixture(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await catalog.close();
        await temp.delete(recursive: true);
      });
    });
    final fixture = (await tester.runAsync(() async {
      final old = await source.copy(p.join(temp.path, 'old.png'));
      final bytes = await source.readAsBytes();
      final blocked = Directory(
        p.join(
          p.dirname(catalog.store.path),
          'film_custom_artwork',
          '${sha256.convert(bytes)}.img',
        ),
      );
      await blocked.create(recursive: true);
      await catalog.store.setBackgroundPath(old.path);
      await catalog.refresh();
      return (old, blocked, bytes);
    }))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFilmArtworkPicker(context, catalog),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await settle(tester);
    await tester.runAsync(() => tester.tap(find.text('Fixture')));
    await settle(tester);
    expect(catalog.error, 'catalogStorageFailed');
    expect(catalog.backgroundFile?.path, fixture.$1.path);
    expect(catalog.backgroundRevision, 0);
    await tester.runAsync(() async {
      expect(await catalog.store.backgroundPath(), fixture.$1.path);
      expect(await fixture.$1.readAsBytes(), fixture.$3);
      expect(await File('${fixture.$2.path}.tmp').exists(), isFalse);
    });
  });

  testWidgets('已知边界：目录迁移保留旧绝对背景路径，同目录仅覆盖程序不损坏图片', (tester) async {
    final (temp, catalog, source) = await backgroundFixture(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await catalog.close();
        await temp.delete(recursive: true);
      });
    });
    await tester.runAsync(() async {
      final custom = File(
        p.join(temp.path, 'library', 'film_custom_artwork', 'fixture.img'),
      );
      await custom.parent.create(recursive: true);
      await source.copy(custom.path);
      await catalog.store.setBackgroundPath(custom.path);
      final program = File(p.join(temp.path, 'streampath.exe'));
      await program.writeAsString('old program');
      await program.writeAsString('new program');
      await catalog.refresh();
      expect(await catalog.backgroundFile!.exists(), isTrue);
      final moved = Directory(p.join(temp.path, 'moved_artwork'));
      await custom.parent.rename(moved.path);
      expect(await File(p.join(moved.path, 'fixture.img')).exists(), isTrue);
      expect(await catalog.backgroundFile!.exists(), isFalse);
      await moved.rename(custom.parent.path);
    });
  });
}
