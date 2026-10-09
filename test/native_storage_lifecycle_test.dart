import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/media_connection_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/native_storage_source.dart';
import 'helpers/shell_test_app_state.dart';

class _HeldSecrets extends MediaConnectionStore {
  _HeldSecrets(super.file);
  final started = Completer<void>();
  final released = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> secrets(String id) {
    started.complete();
    return released.future;
  }
}

class _App extends ShellTestAppState {
  _App({
    required this.store,
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
  });
  final _HeldSecrets store;
  @override
  Future<MediaConnectionStore> getMediaConnections() async => store;
}

void main() {
  test(
    'removed or replaced native connection cannot mount stale credentials',
    () async {
      for (final remove in [false, true]) {
        final root = await Directory.systemTemp.createTemp('sp_stale_native_');
        final store = _HeldSecrets(File(p.join(root.path, 'sources.json')));
        final config = MediaConnection(
          id: 'smb:stale-test',
          kind: MediaSourceKind.smb,
          name: 'Fixture',
          url: 'smb://127.0.0.1/share',
        );
        store.connections.add(config);
        final progress = await PlaybackProgressService.open(
          p.join(root.path, 'progress.db'),
        );
        final app = _App(
          store: store,
          configStore: StreamPathConfigStore.forPath(
            p.join(root.path, 'config.json'),
          ),
          playbackHistoryStore: PlaybackHistoryStore.forPath(
            p.join(root.path, 'history.json'),
          ),
          progressService: progress,
        );
        try {
          final mount = app.mountMediaConnection(config.id);
          final rejected = expectLater(
            mount,
            throwsA(
              isA<FilmCatalogException>().having(
                (e) => e.code,
                'code',
                'sourceUnavailable',
              ),
            ),
          );
          await store.started.future;
          store.connections.clear();
          if (!remove) {
            store.connections.add(
              MediaConnection.fromJson({
                ...config.toJson(),
                'username': 'new-user',
              }),
            );
          }
          store.released.complete({'password': 'old-password'});
          await rejected;
          expect(app.nativeSource(config.id), isNull);
          await app.prepareForClose();
        } finally {
          app.dispose();
          await app.closeTestStores();
          await progress.close();
          await root.delete(recursive: true);
        }
      }
    },
    skip: !Platform.isWindows,
  );
  test('failed in-flight native mount does not prevent shutdown', () async {
    final root = await Directory.systemTemp.createTemp('sp_shutdown_audit_');
    final store = _HeldSecrets(File(p.join(root.path, 'sources.json')));
    final config = MediaConnection(
      id: 'ftp:shutdown-audit',
      kind: MediaSourceKind.ftp,
      name: 'Fixture',
      url: 'ftp://127.0.0.1/',
      username: 'fixture',
    );
    store.connections.add(config);
    final progress = await PlaybackProgressService.open(
      p.join(root.path, 'progress.db'),
    );
    final app = _App(
      store: store,
      configStore: StreamPathConfigStore.forPath(
        p.join(root.path, 'config.json'),
      ),
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(root.path, 'history.json'),
      ),
      progressService: progress,
    );
    try {
      final mount = app.mountMediaConnection(config.id);
      final mountFailure = expectLater(
        mount,
        throwsA(isA<FilmCatalogException>()),
      );
      await store.started.future;
      final firstClose = app.prepareForClose();
      final firstResult = firstClose;
      await Future<void>.delayed(Duration.zero);
      store.released.completeError(
        const FilmCatalogException('credentialStoreFailed'),
      );
      await mountFailure;
      await firstResult;
      final secondClose = app.prepareForClose();
      expect(identical(firstClose, secondClose), isTrue);
      await secondClose;
      expect(app.nativeSource(config.id), isNull);
    } finally {
      app.dispose();
      await app.closeTestStores();
      await progress.close();
      await root.delete(recursive: true);
    }
  });
  test(
    'credentials remain isolated and survive reload and failed config writes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sp_credentials_audit_',
      );
      final store = MediaConnectionStore(
        File(p.join(root.path, 'sources.json')),
      );
      final config = MediaConnection(
        id: MediaConnection.newId(MediaSourceKind.ftp),
        kind: MediaSourceKind.ftp,
        name: 'Fixture',
        url: 'ftp://127.0.0.1/',
        username: 'fixture',
      );
      addTearDown(() async {
        await store.credential(config.id).delete();
        await root.delete(recursive: true);
      });
      await store.save(config, secrets: {'password': '  fixture password  '});
      expect(
        await store.file.readAsString(),
        isNot(contains('fixture password')),
      );
      final reloaded = MediaConnectionStore(store.file);
      await reloaded.load();
      expect(reloaded.connections.single.id, config.id);
      expect(
        (await reloaded.secrets(config.id))['password'],
        '  fixture password  ',
      );
      await Directory('${store.file.path}.partial').create();
      await expectLater(
        store.save(config, secrets: {'password': 'new-password'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        (await store.secrets(config.id))['password'],
        '  fixture password  ',
      );
      await Directory('${store.file.path}.partial').delete();
      await store.remove(config.id);
      expect(await store.secrets(config.id), isEmpty);
    },
    skip: !Platform.isWindows,
  );
  test(
    'closing cancels stalled FTP listing and releases the worker',
    () async {
      final root = await Directory.systemTemp.createTemp('sp_cancel_audit_');
      final process =
          await Process.start(Platform.environment['PHASE5_PYTHON']!, [
            'test/support/storage_ftp_fixture.py',
            root.path,
            p.absolute('build/phase5-test-deps'),
            'stall',
          ]);
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      process.stderr.drain<void>();
      addTearDown(() async {
        await lines.cancel();
        process.kill();
        await process.exitCode;
        await root.delete(recursive: true);
      });
      await lines.moveNext();
      final port = (jsonDecode(lines.current) as Map)['port'];
      final source = await NativeStorageSource.open(
        MediaConnection(
          id: 'ftp:cancel-audit',
          kind: MediaSourceKind.ftp,
          name: 'Fixture',
          url: 'ftp://127.0.0.1:$port/',
          username: 'fixture',
        ),
        'fixture',
        libraryPath: p.absolute(
          'build/windows/x64/runner/Release/streampath_storage.dll',
        ),
      );
      final pending = source.fetchDirectory('');
      final rejected = expectLater(
        pending,
        throwsA(
          isA<FilmCatalogException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await lines.moveNext();
      expect(lines.current, 'listing-started');
      final timer = Stopwatch()..start();
      await source.close().timeout(const Duration(seconds: 5));
      await rejected;
      expect(timer.elapsedMilliseconds, lessThan(5000));
      await source.close();
    },
    skip: Platform.environment['PHASE5_PYTHON'] == null || !Platform.isWindows,
  );
}
