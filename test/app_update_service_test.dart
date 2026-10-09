import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/app_update_service.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/localization/app_update_translations.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/app_update_settings_card.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';

class _ReleaseAdapter implements HttpClientAdapter {
  _ReleaseAdapter(this.reply);
  final ResponseBody Function(RequestOptions) reply;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => reply(options);
  @override
  void close({bool force = false}) {}
}

void main() {
  const name = 'StreamPath.20261010.V1.1.portable.zip';
  final payload = utf8.encode('synthetic release payload');
  final hash = sha256.convert(payload).toString();
  Map<String, dynamic> apiRelease() => {
    'draft': false,
    'prerelease': false,
    'tag_name': 'v1.1',
    'assets': [
      {
        'name': 'StreamPath.release.json',
        'size': 1024,
        'browser_download_url':
            'https://github.com/Yufuxk/StreamPath-OpenList-MPV-Linker/releases/download/v1.1/StreamPath.release.json',
      },
      {
        'name': name,
        'size': payload.length,
        'digest': 'sha256:$hash',
        'browser_download_url':
            'https://github.com/Yufuxk/StreamPath-OpenList-MPV-Linker/releases/download/v1.1/$name',
      },
    ],
  };
  Map<String, dynamic> metadata() => {
    'schema': 1,
    'version': '1.1.0',
    'build': 2,
    'displayVersion': '1.1',
    'date': '20261010',
    'assets': [
      {
        'name': name,
        'kind': 'portable',
        'platform': 'windows-x64',
        'size': payload.length,
        'sha256': hash,
      },
    ],
  };

  test('版本比较统一 GitHub 两段版本、三段版本和构建号', () {
    expect(
      AppReleaseVersion.parse(
        'v1.0',
      ).compareTo(AppReleaseVersion.parse('1.0.0')),
      0,
    );
    expect(
      AppReleaseVersion.parse(
        '1.0.0+2',
      ).compareTo(AppReleaseVersion.parse('1.0.0+1')),
      greaterThan(0),
    );
    expect(
      AppReleaseVersion.parse(
        '1.10.0+1',
      ).compareTo(AppReleaseVersion.parse('1.9.0+100')),
      greaterThan(0),
    );
    for (final invalid in ['1', '01.0', '1.0beta', '1.0.0.1', '1.65536']) {
      expect(() => AppReleaseVersion.parse(invalid), throwsFormatException);
    }
  });

  test('精确匹配发布名称、类型、版本、平台与 GitHub digest', () {
    final result = AppUpdateAsset.fromRelease(
      apiRelease(),
      metadata(),
      'portable',
    );
    expect(result.version.toString(), '1.1.0+2');
    expect(result.name, name);
    expect(
      () => AppUpdateAsset.fromRelease(apiRelease(), metadata(), 'installed'),
      throwsFormatException,
    );
    final wrong = metadata();
    (wrong['assets'] as List).single['platform'] = 'linux-x64';
    expect(
      () => AppUpdateAsset.fromRelease(apiRelease(), wrong, 'portable'),
      throwsFormatException,
    );
    final api = apiRelease();
    (api['assets'] as List).last['digest'] = 'sha256:${'a' * 64}';
    expect(
      () => AppUpdateAsset.fromRelease(api, metadata(), 'portable'),
      throwsFormatException,
    );
    expect(
      () => AppUpdateAsset.fromRelease(
        {...apiRelease(), 'prerelease': true},
        metadata(),
        'portable',
      ),
      throwsFormatException,
    );
    expect(
      () => AppUpdateAsset.fromRelease(
        {...apiRelease(), 'tag_name': 'v1.2'},
        metadata(),
        'portable',
      ),
      throwsFormatException,
    );
  });

  test('拒绝其他仓库、HTTP、凭据、查询与路径逃逸', () {
    for (final url in [
      'https://github.com/other/repo/releases/download/v1.1/$name',
      'http://github.com/Yufuxk/StreamPath-OpenList-MPV-Linker/releases/download/v1.1/$name',
      'https://token@github.com/Yufuxk/StreamPath-OpenList-MPV-Linker/releases/download/v1.1/$name',
      'https://github.com/Yufuxk/StreamPath-OpenList-MPV-Linker/releases/download/v1.1/$name?token=secret',
    ]) {
      expect(
        () => AppUpdateAsset.trustedAssetUri(url, 'v1.1', name),
        throwsFormatException,
      );
    }
  });

  for (final scenario in [
    'success',
    'digest',
    'truncated',
    'old',
    'missingType',
  ]) {
    test('实际流式下载 $scenario 保留用户文件', () async {
      final directory = await Directory.systemTemp.createTemp(
        'sp-update-test-',
      );
      final preserved = File('${directory.path}/user-cache.json');
      await preserved.writeAsString('preserve settings and playback');
      final meta = metadata();
      if (scenario == 'old') {
        meta['version'] = '1.0.0';
      }
      if (scenario == 'missingType') {
        (meta['assets'] as List).single['kind'] = 'installed';
      }
      final client = Dio();
      var downloads = 0;
      client.httpClientAdapter = _ReleaseAdapter((request) {
        if (request.path.contains('/releases/latest')) {
          return ResponseBody.fromString(
            jsonEncode(apiRelease()),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }
        if (request.path.endsWith('StreamPath.release.json')) {
          return ResponseBody.fromString(jsonEncode(meta), 200);
        }
        downloads++;
        final bytes = scenario == 'digest'
            ? List<int>.filled(payload.length, 120)
            : scenario == 'truncated'
            ? payload.sublist(1)
            : payload;
        return ResponseBody.fromBytes(bytes, 200);
      });
      final service = AppUpdateService(
        appDirectory: directory,
        version: AppReleaseVersion.parse('1.0.0+2'),
        installed: false,
        client: client,
        downloadDirectory: Directory('${directory.path}/downloads'),
      );
      try {
        await service.check();
        expect(
          await preserved.readAsString(),
          'preserve settings and playback',
        );
        if (scenario == 'success') {
          expect(service.status, AppUpdateStatus.ready);
          expect(await service.package!.readAsBytes(), payload);
          await service.check();
          expect(downloads, 1, reason: '相同已校验版本不能重复下载');
          final reloaded = AppUpdateService(
            appDirectory: directory,
            version: AppReleaseVersion.parse('1.0.0+2'),
            installed: false,
            client: Dio()..httpClientAdapter = client.httpClientAdapter,
            downloadDirectory: Directory('${directory.path}/downloads'),
          );
          try {
            await reloaded.check();
            expect(reloaded.status, AppUpdateStatus.ready);
            expect(downloads, 1, reason: '重新启动后复用完整且已校验的更新包');
            await reloaded.package!.writeAsBytes(
              List<int>.filled(payload.length, 120),
            );
            reloaded.package = null;
            await reloaded.check();
            expect(downloads, 2, reason: '损坏的本地更新包必须重新下载');
            expect(await reloaded.package!.readAsBytes(), payload);
          } finally {
            reloaded.dispose();
          }
          await expectLater(
            service.restartToUpdate(busyWithUserData: () async => true),
            throwsA(isA<AppUpdateBlocked>()),
          );
          expect(service.status, AppUpdateStatus.ready);
        } else if (scenario == 'old') {
          expect(service.status, AppUpdateStatus.current);
          expect(downloads, 0);
        } else {
          expect(service.status, AppUpdateStatus.unavailable);
          expect(service.package, isNull);
          expect(
            directory
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.path.endsWith('.partial')),
            isEmpty,
          );
        }
      } finally {
        service.dispose();
        await directory.delete(recursive: true);
      }
    });
  }

  test('更新界面四语言覆盖且占位符一致', () {
    final placeholders = RegExp(r'\{\w+\}');
    for (final entry in appUpdateTranslations.entries) {
      expect(entry.value.length, 3);
      for (final language in AppLanguage.values) {
        final translated = AppLocalizations(language).text(entry.key);
        expect(translated, isNotEmpty);
        expect(
          placeholders.allMatches(translated).map((v) => v[0]).toSet(),
          placeholders.allMatches(entry.key).map((v) => v[0]).toSet(),
        );
        if (language == AppLanguage.english) {
          expect(translated, isNot(contains(RegExp(r'[\u4e00-\u9fff]'))));
        }
      }
    }
  });

  for (final language in AppLanguage.values) {
    testWidgets('更新卡片窄窗大字体可检查并展示重启入口 ${language.name}', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = Dio()
        ..httpClientAdapter = _ReleaseAdapter(
          (_) => ResponseBody.fromString('', 503),
        );
      final service = AppUpdateService(
        appDirectory: Directory.systemTemp,
        version: AppReleaseVersion.parse('1.0.0+2'),
        installed: false,
        client: client,
      );
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: language.locale,
          supportedLocales: AppLanguage.values.map((value) => value.locale),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: DirectoryScrollView(
              builder: (controller) => SingleChildScrollView(
                controller: controller,
                padding: const EdgeInsets.all(16),
                child: AppUpdateSettingsCard(service: service),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final check = find.byKey(const Key('check-app-update'));
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(service.status, AppUpdateStatus.failed);
      expect(
        find.text(AppLocalizations(language).text('更新检查或下载失败，可重试')),
        findsOneWidget,
      );
      await service.cancelRestart();
      await tester.pumpAndSettle();
      final restart = find.byKey(const Key('restart-app-update'));
      await tester.ensureVisible(restart);
      expect(restart, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
