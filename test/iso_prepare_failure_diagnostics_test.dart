import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/models/webdav_bdmv.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/iso_access_provider.dart';
import 'package:streampath/domain/services/webdav_service.dart';

void main() {
  final helper =
      Platform.environment['STREAMPATH_BLURAY_HELPER'] ??
      'build/windows/x64/runner/Release/streampath_iso_bridge.exe';
  test(
    '真实 helper 的准备 HTTP 错误在会话清理后仍保留诊断',
    () async {
      final root = await Directory.systemTemp.createTemp('iso-helper-failure-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 503;
        request.response.contentLength = 0;
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      final base = 'http://127.0.0.1:${server.port}';
      final source = WebDAVService(
        client: WebDavClient(baseUrl: base),
        profileId: 'test-failure',
      );
      final disc = WebDavBdmv(
        name: 'Disc',
        href: '/',
        rootPath: '',
        files: [
          {
            'type': 'disc_file',
            'path': 'BDMV',
            'url': '$base/BDMV',
            'size': 0,
            'directory': true,
          },
          {
            'type': 'disc_file',
            'path': 'BDMV/index.bdmv',
            'url': '$base/BDMV/index.bdmv',
            'size': 8,
            'directory': false,
            'etag': '"v1"',
          },
        ],
      );
      final session = Directory(p.join(root.path, 'iso_temp', 'session'));
      final provider = IsoBridgeAccessProvider(
        helperPathResolver: () async => p.absolute(helper),
      );
      await expectLater(
        provider.prepare(
          webDavService: source,
          file: disc,
          sessionDirectory: session,
          structureCachePath: p.join(
            root.path,
            'iso_structure',
            '${List.filled(64, 'a').join()}.cache',
          ),
        ),
        throwsA(isA<AppException>()),
      );
      expect(await session.exists(), false);
      final text = await File(
        p.join(root.path, 'iso_benchmarks', 'last-prepare-failure-title.json'),
      ).readAsString();
      final record = jsonDecode(text) as Map;
      expect(record['code'], 'network_error');
      expect(record['httpStatus'], 503);
      expect(text, isNot(contains(base)));
    },
    skip: !Platform.isWindows || !File(helper).existsSync(),
  );

  test('准备失败保留 HTTP 状态与计数，清理会话后仍可读取且不保存来源信息', () async {
    final root = await Directory.systemTemp.createTemp(
      'iso-failure-diagnostic-',
    );
    addTearDown(() => root.delete(recursive: true));
    final session = await Directory(
      p.join(root.path, 'iso_temp', 'session'),
    ).create(recursive: true);
    await File(p.join(session.path, 'iso-bridge-metrics.json')).writeAsString(
      jsonEncode({
        'network': {
          'requestCount': 17,
          'remoteBodyBytes': 300,
          'url': 'https://private.example/secret?token=credential',
          'authorization': 'private-password',
        },
        'metadataCache': {'cacheMissCount': 8},
      }),
    );
    for (final menu in [false, true]) {
      await IsoBridgeAccessProvider.archivePreparationFailure(
        session,
        remoteMenu: menu,
        phase: IsoAccessPhase.parsingTitles,
        elapsedMs: 3200,
        code: 'network_error',
        httpStatus: 429,
        failureKind: 'bridge',
      );
    }
    await session.delete(recursive: true);
    final archive = Directory(p.join(root.path, 'iso_benchmarks'));
    expect(await archive.list().length, 2);
    for (final menu in [false, true]) {
      final text = await File(
        p.join(
          archive.path,
          'last-prepare-failure-${menu ? 'menu' : 'title'}.json',
        ),
      ).readAsString();
      final record = jsonDecode(text) as Map;
      expect(record['code'], 'network_error');
      expect(record['httpStatus'], 429);
      expect(record['phase'], 'parsingTitles');
      expect(record['network'], {'requestCount': 17, 'remoteBodyBytes': 300});
      expect(record['metadataCache'], {'cacheMissCount': 8});
      expect(text, isNot(contains('private')));
      expect(text, isNot(contains('credential')));
    }
  });

  test('损坏的快照不阻断失败归档，固定槽位覆盖旧记录', () async {
    final root = await Directory.systemTemp.createTemp('iso-failure-invalid-');
    addTearDown(() => root.delete(recursive: true));
    final session = await Directory(
      p.join(root.path, 'iso_temp', 'session'),
    ).create(recursive: true);
    await File(
      p.join(session.path, 'iso-bridge-metrics.json'),
    ).writeAsString('{broken');
    for (final elapsed in [1, 2]) {
      await IsoBridgeAccessProvider.archivePreparationFailure(
        session,
        remoteMenu: false,
        phase: IsoAccessPhase.probingStream,
        elapsedMs: elapsed,
        code: 'https://private/credential',
        httpStatus: -1,
        failureKind: 'timeout',
      );
    }
    final archive = Directory(p.join(root.path, 'iso_benchmarks'));
    expect(await archive.list().length, 1);
    final record =
        jsonDecode(
              await File(
                p.join(archive.path, 'last-prepare-failure-title.json'),
              ).readAsString(),
            )
            as Map;
    expect(record['metricsInvalid'], true);
    expect(record['code'], 'unknown');
    expect(record['elapsedMs'], 2);
    expect(record.containsKey('httpStatus'), false);
  });
}
