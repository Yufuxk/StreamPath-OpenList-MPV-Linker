import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/pages/media_connections_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'helpers/shell_test_app_state.dart';
import 'helpers/pump_until.dart';

class _Fixture {
  _Fixture(this.directory, this.progress, this.app, this.server);
  final Directory directory;
  final PlaybackProgressService progress;
  final ShellTestAppState app;
  final HttpServer server;
  bool rejectLogin = false;
  int verifications = 0;
  String? heldPath;
  Completer<void>? requestStarted, releaseRequest;
  Future<void> close() async {
    await app.prepareForClose();
    final connections = await app.getMediaConnections();
    for (final row in connections.connections.toList()) {
      await connections.remove(row.id);
    }
    app.dispose();
    await app.closeTestStores();
    await progress.close();
    await server.close(force: true);
    await directory.delete(recursive: true);
  }

  static Future<_Fixture> open() async {
    final directory = await Directory.systemTemp.createTemp(
      'sp_connection_test_',
    );
    final progress = await PlaybackProgressService.open(
      '${directory.path}/progress.db',
    );
    final app = ShellTestAppState(
      configStore: StreamPathConfigStore.forPath(
        '${directory.path}/config.json',
      ),
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        '${directory.path}/history.json',
      ),
      progressService: progress,
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _Fixture(directory, progress, app, server);
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == fixture.heldPath) {
        fixture.requestStarted!.complete();
        await fixture.releaseRequest!.future;
      }
      if (request.uri.path == '/Users/AuthenticateByName') {
        request.response.statusCode = fixture.rejectLogin ? 401 : 200;
        request.response.write(
          jsonEncode({
            'AccessToken': 'test-token',
            'User': {'Id': 'test-user'},
            'ServerId': 'test-server',
          }),
        );
      } else if (request.uri.path == '/Users/test-user') {
        fixture.verifications++;
        request.response.write('{}');
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    return fixture;
  }
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  test(
    'concurrent mount completes and a subsequent mount does not self-await',
    () async {
      final fixture = await _Fixture.open();
      addTearDown(fixture.close);
      final c = MediaConnection(
        id: MediaConnection.newId(MediaSourceKind.jellyfin),
        kind: MediaSourceKind.jellyfin,
        name: 'Fixture',
        url: 'http://127.0.0.1:${fixture.server.port}',
      );
      await fixture.app.saveMediaConnection(
        c,
        secrets: {
          'token': 'test-token',
          'userId': 'test-user',
          'serverId': 'test-server',
        },
      );
      final first = fixture.app.mountMediaConnection(c.id);
      final concurrent = fixture.app.mountMediaConnection(c.id);
      expect(identical(first, concurrent), isTrue);
      await Future.wait([
        first,
        concurrent,
      ]).timeout(const Duration(seconds: 2));
      expect(fixture.verifications, 1);
      await fixture.app
          .mountMediaConnection(c.id)
          .timeout(const Duration(seconds: 2));
      expect(fixture.verifications, 1);
      expect(fixture.app.serverSource(c.id), isNotNull);
    },
    skip: !Platform.isWindows,
  );

  for (final authenticate in [false, true]) {
    test(
      'deleting a source during ${authenticate ? 'authentication' : 'verification'} cannot recreate it',
      () async {
        final fixture = await _Fixture.open();
        addTearDown(fixture.close);
        final config = MediaConnection(
          id: MediaConnection.newId(MediaSourceKind.jellyfin),
          kind: MediaSourceKind.jellyfin,
          name: 'Fixture',
          url: 'http://127.0.0.1:${fixture.server.port}',
          username: 'Test',
        );
        await fixture.app.saveMediaConnection(
          config,
          secrets: authenticate
              ? {'password': 'test-password'}
              : {
                  'token': 'test-token',
                  'userId': 'test-user',
                  'serverId': 'test-server',
                },
        );
        fixture.heldPath = authenticate
            ? '/Users/AuthenticateByName'
            : '/Users/test-user';
        fixture.requestStarted = Completer<void>();
        fixture.releaseRequest = Completer<void>();
        final mount = fixture.app.mountMediaConnection(config.id);
        final result = expectLater(
          mount,
          throwsA(
            isA<FilmCatalogException>().having(
              (e) => e.code,
              'code',
              'sourceUnavailable',
            ),
          ),
        );
        await fixture.requestStarted!.future.timeout(
          const Duration(seconds: 2),
        );
        await fixture.app.removeMediaConnection(config.id);
        fixture.releaseRequest!.complete();
        await result;
        expect(fixture.app.mediaConnections, isEmpty);
        expect(fixture.app.serverSource(config.id), isNull);
        expect(
          await (await fixture.app.getFilmCatalogStore()).roots(),
          isEmpty,
        );
      },
      skip: !Platform.isWindows,
    );
  }

  for (final reject in [false, true]) {
    testWidgets(
      'connection editor finishes verification with ${reject ? 'a visible login error' : 'a saved, mounted source'}',
      (tester) async {
        final previousOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        final fixture = (await tester.runAsync(_Fixture.open))!;
        await tester.runAsync(() => fixture.app.getMediaConnections());
        fixture.rejectLogin = reject;
        try {
          await tester.pumpWidget(
            ChangeNotifierProvider<AppState>.value(
              value: fixture.app,
              child: MaterialApp(
                locale: const Locale('zh', 'CN'),
                supportedLocales: const [Locale('zh', 'CN')],
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                home: const Scaffold(body: MediaConnectionsPage(servers: true)),
              ),
            ),
          );
          await tester.pump();
          await tester.tap(find.text('添加媒体服务器'));
          await tester.pumpAndSettle();
          final fields = find.byType(TextField);
          await tester.enterText(fields.at(0), 'Fixture');
          await tester.enterText(
            fields.at(1),
            'http://127.0.0.1:${fixture.server.port}',
          );
          await tester.enterText(fields.at(2), 'Test');
          await tester.enterText(fields.at(3), 'test-password');
          await tester.runAsync(() async {
            await tester.tap(find.text('验证并保存'));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });
          await tester.pump();
          await pumpUntil(
            tester,
            () => find.text('正在验证…').evaluate().isEmpty,
            reason:
                'Server verification must finish before checking its result',
          );
          expect(find.text('正在验证…'), findsNothing);
          await tester.pumpAndSettle();
          if (reject) {
            expect(find.text('验证并保存'), findsOneWidget);
            expect(fixture.app.mediaConnections, isEmpty);
            expect(find.text('服务器认证失败，请重新登录'), findsOneWidget);
          } else {
            expect(find.text('验证并保存'), findsNothing);
            expect(fixture.app.mediaConnections, hasLength(1));
            expect(
              fixture.app.serverSource(fixture.app.mediaConnections.single.id),
              isNotNull,
            );
            final verified = fixture.verifications;
            await tester.tap(find.text('Fixture · JELLYFIN'));
            await tester.pumpAndSettle();
            expect(fixture.verifications, verified);
            await tester.runAsync(() async {
              await tester.tap(find.byTooltip('验证连接'));
              await Future<void>.delayed(const Duration(milliseconds: 100));
            });
            await tester.pumpAndSettle();
            expect(fixture.verifications, verified + 1);
            expect(find.text('连接成功'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(fixture.close);
          HttpOverrides.global = previousOverrides;
        }
      },
      skip: !Platform.isWindows,
    );
  }
}
