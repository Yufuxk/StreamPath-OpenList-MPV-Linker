import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/video_playlist_mode.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/webdav_font_localizer.dart';
import 'package:streampath/domain/services/webdav_font_matcher.dart';
import 'package:streampath/presentation/pages/browser_page.dart';
import 'package:streampath/presentation/state/app_state.dart';

import 'helpers/pump_until.dart';
import 'helpers/shell_test_app_state.dart';

enum _FontState { downloading, cached, absent }

class _ProgressPlayer extends ExternalPlayerService {
  _ProgressPlayer({required super.configStore, required this.fontState});

  final _FontState fontState;
  final release = Completer<void>();
  bool arrived = false;
  bool hasFontCallback = false;
  int fonts = 0;
  void Function(String)? reportStage;

  @override
  Future<void> captureOpenListProcessIdentity() async {}

  @override
  Future<PlayerLaunchResult> launch({
    required List<MediaEntry> entries,
    String? sessionId,
    int playlistStart = 0,
    int? resumeSeconds,
    String? username,
    String? password,
    String? webDavSourceUrl,
    String? webDavSourceId,
    bool automaticRecovery = false,
    WebDavFontDirectory? webDavFonts,
    List<WebDavFontDirectory?>? webDavFontsByEntry,
    List<String?>? localFontDirectories,
    WebDavFontBytesLoader? webDavFontLoader,
    WebDavFontFileLoader? webDavFontFileLoader,
    void Function(WebDavFontLocalizationProgress)? onFontProgress,
    void Function(String)? onPreparationStage,
    SeasonPlaybackEntries? nextSeason,
    ImplicitVideoPlan? implicitPlan,
  }) async {
    fonts =
        webDavFontsByEntry?.firstOrNull?.files.length ??
        webDavFonts?.files.length ??
        0;
    hasFontCallback = onFontProgress != null;
    reportStage = onPreparationStage;
    if (fontState != _FontState.absent) {
      final cached = fontState == _FontState.cached;
      onFontProgress?.call(
        WebDavFontLocalizationProgress(
          completedFiles: cached ? 1 : 0,
          totalFiles: 1,
          receivedBytes: cached ? 0 : 12288,
          expectedBytes: cached ? 0 : 24576,
          fileName: cached ? 'Fonts' : 'progress.ttf',
          fromCache: cached,
        ),
      );
    }
    arrived = true;
    await release.future;
    throw AppException.process('Fixture launch stopped');
  }
}

String _entry(String href, String name, {bool directory = false}) =>
    '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
    '<d:displayname>$name</d:displayname><d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype>'
    '<d:getcontentlength>24576</d:getcontentlength></d:prop>'
    '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';

void main() {
  for (final mode in VideoPlaylistMode.values) {
    for (final fontState in _FontState.values) {
      testWidgets(
        'preparation progress mode=${mode.name} fonts=${fontState.name}',
        (tester) async {
          final previousOverrides = HttpOverrides.current;
          HttpOverrides.global = null;
          addTearDown(() => HttpOverrides.global = previousOverrides);
          final fixture = (await tester.runAsync(() async {
            final temp = await Directory.systemTemp.createTemp(
              'font_progress_',
            );
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            server.listen((request) async {
              request.response.statusCode = HttpStatus.multiStatus;
              request.response.headers.contentType = ContentType(
                'application',
                'xml',
                charset: 'utf-8',
              );
              final content = request.uri.path.contains('/Fonts')
                  ? _entry('/dav/Fonts/', 'Fonts', directory: true) +
                        _entry('/dav/Fonts/progress.ttf', 'progress.ttf')
                  : _entry('/dav/', 'root', directory: true) +
                        _entry('/dav/episode.strm', 'episode.strm') +
                        _entry('/dav/episode.ass', 'episode.ass') +
                        (fontState == _FontState.absent
                            ? ''
                            : _entry('/dav/Fonts/', 'Fonts', directory: true));
              if (request.method == 'GET' &&
                  request.uri.path.endsWith('.strm')) {
                request.response.statusCode = HttpStatus.ok;
                request.response.write(
                  'http://127.0.0.1:${server.port}/media/episode.mkv',
                );
              } else {
                request.response.write(
                  '<d:multistatus xmlns:d="DAV:">$content</d:multistatus>',
                );
              }
              await request.response.close();
            });
            final config = StreamPathConfigStore.forPath(
              '${temp.path}/config.json',
            );
            await config.save(
              StreamPathConfig(
                playerExecutable: 'fixture_mpv.exe',
                videoPlaylistMode: mode,
                subtitleInjectionEnabled: true,
                sharePlaylistFonts: false,
                autoSeasonTransitionEnabled: false,
              ),
            );
            final player = _ProgressPlayer(
              configStore: config,
              fontState: fontState,
            );
            final progress = await PlaybackProgressService.open(
              '${temp.path}/progress.db',
            );
            final app = ShellTestAppState(
              configStore: config,
              playbackHistoryStore: PlaybackHistoryStore.forPath(
                '${temp.path}/history.json',
              ),
              playerService: player,
              progressService: progress,
            );
            await app.connect(
              baseUrl: 'http://127.0.0.1:${server.port}/dav',
              username: '',
              password: '',
            );
            return (temp, server, player, progress, app);
          }))!;
          final (temp, server, player, progress, app) = fixture;
          var cleaned = false;
          Future<void> cleanup() async {
            if (cleaned) return;
            cleaned = true;
            if (!player.release.isCompleted) player.release.complete();
            await tester.pumpWidget(const SizedBox.shrink());
            var finished = false;
            await tester.runAsync(() async {
              unawaited(() async {
                app.dispose();
                await app.closeTestStores();
                await progress.close();
                await server.close(force: true);
                await temp.delete(recursive: true);
                finished = true;
              }());
            });
            await pumpUntil(
              tester,
              () => finished,
              reason: 'Fixture I/O closes',
            );
            // 释放回环 HTTP 连接的空闲计时器。
            await tester.pump(const Duration(seconds: 4));
          }

          addTearDown(cleanup);
          try {
            await tester.pumpWidget(
              ChangeNotifierProvider<AppState>.value(
                value: app,
                child: const MaterialApp(home: BrowserPage()),
              ),
            );
            await pumpUntil(
              tester,
              () => find.text('episode.strm').evaluate().isNotEmpty,
              reason: 'Directory ready',
            );
            await tester.runAsync(
              () => tester.tap(find.text('episode.strm').first),
            );
            await pumpUntil(
              tester,
              () => player.arrived,
              reason: 'Launch reached',
            );
            await tester.pump();
            final dialog = find.byKey(
              const Key('webdav-video-preparation-dialog'),
            );
            Finder textInDialog(String text) =>
                find.descendant(of: dialog, matching: find.text(text));
            LinearProgressIndicator progressBar() =>
                tester.widget<LinearProgressIndicator>(
                  find.descendant(
                    of: dialog,
                    matching: find.byType(LinearProgressIndicator),
                  ),
                );

            expect(dialog, findsOneWidget);
            expect(player.fonts, fontState == _FontState.absent ? 0 : 1);
            expect(player.hasFontCallback, isTrue);
            expect(player.reportStage, isNotNull);
            switch (fontState) {
              case _FontState.downloading:
                expect(textInDialog('正在下载外挂字体…'), findsOneWidget);
                expect(textInDialog('progress.ttf'), findsOneWidget);
                expect(textInDialog('0/1 · 12 KiB / 24 KiB'), findsOneWidget);
                expect(progressBar().value, .5);
              case _FontState.cached:
                expect(textInDialog('已使用缓存字体'), findsOneWidget);
                expect(textInDialog('Fonts'), findsOneWidget);
                expect(textInDialog('1/1'), findsOneWidget);
                expect(progressBar().value, isNull);
              case _FontState.absent:
                expect(textInDialog('正在启动播放器…'), findsOneWidget);
                expect(textInDialog('progress.ttf'), findsNothing);
                expect(textInDialog('正在下载外挂字体…'), findsNothing);
                expect(progressBar().value, isNull);
            }
            player.reportStage!('正在启动播放器…');
            await tester.pump();
            expect(textInDialog('正在启动播放器…'), findsOneWidget);
            expect(textInDialog('progress.ttf'), findsNothing);
            expect(textInDialog('Fonts'), findsNothing);
            expect(progressBar().value, isNull);

            player.release.complete();
            await pumpUntil(
              tester,
              () => dialog.evaluate().isEmpty,
              reason: 'Preparation dialog closes after launch failure',
            );
            expect(tester.takeException(), isNull);
          } finally {
            await cleanup();
          }
        },
      );
    }
  }
}
