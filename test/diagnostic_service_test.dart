import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/profile_credential_store.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/openlist_index_config.dart';
import 'package:streampath/data/models/openlist_recovery_config.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/diagnostic_service.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/openlist_api_client.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('URL 描述只保留来源并把路径转换为摘要', () {
    final descriptor = diagnosticUrlDescriptor(
      'https://alice:secret@example.test:8443/dav/private/movie.mkv?token=x#part',
    );

    expect(descriptor['origin'], 'https://example.test:8443');
    expect(descriptor['pathHash'], startsWith('sha256:'));
    expect(descriptor.toString(), isNot(contains('alice')));
    expect(descriptor.toString(), isNot(contains('private')));
    expect(descriptor.toString(), isNot(contains('token')));
  });

  test('文本脱敏覆盖已知秘密、认证头、userinfo 和签名查询', () {
    final redacted = redactDiagnosticText(
      'password=hunter token=abc Authorization: Bearer token-value '
      'Basic Zm9vOmJhcg== '
      'https://user:pass@example.test/dav/a.mkv?sign=private',
      secrets: const ['hunter', 'abc'],
    );

    expect(redacted, isNot(contains('hunter')));
    expect(redacted, isNot(contains('token-value')));
    expect(redacted, isNot(contains('Zm9vOmJhcg')));
    expect(redacted, isNot(contains('user:pass')));
    expect(redacted, isNot(contains('sign=private')));
    expect(redacted, contains('https://example.test'));
  });

  test('短密码和 IPv6 URL 不会破坏整段 URL 的优先脱敏', () {
    final redacted = redactDiagnosticText(
      'a https://user:pass@[::1]:8443/private?a=query-secret',
      secrets: const ['a'],
    );

    expect(redacted, isNot(contains('user:pass')));
    expect(redacted, isNot(contains('query-secret')));
    expect(redacted, isNot(contains('/private')));
    expect(redacted, contains('https://[::1]:8443'));
  });

  test('OpenList 诊断拒绝 HTML 200 与 JSON code 500 假阳性', () {
    final html = diagnoseOpenListSettingsResponse(
      const OpenListHttpResponse(statusCode: 200, data: '<html>proxy</html>'),
      baseUrl: 'https://openlist.test',
    );
    final apiFailure = diagnoseOpenListSettingsResponse(
      const OpenListHttpResponse(
        statusCode: 200,
        data: {'code': 500, 'message': 'backend failed'},
      ),
      baseUrl: 'https://openlist.test',
    );

    expect(html.status, DiagnosticStatus.failed);
    expect(html.summary, contains('JSON envelope'));
    expect(apiFailure.status, DiagnosticStatus.failed);
    expect(apiFailure.summary, contains('code 500'));
  });

  test('导出的诊断包不会从摘要或嵌套详情泄露凭据', () async {
    final tempDir = Directory.systemTemp.createTempSync('diagnostic_export_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final configPath =
        '${tempDir.path}${Platform.pathSeparator}stream_path_config.json';
    final configStore = StreamPathConfigStore.forPath(
      configPath,
      credentialStore: MemoryProfileCredentialStore(),
    );
    const profile = ServerProfile(
      profileId: 'profile-a',
      name: '可能含敏感信息的名称',
      serverUrl:
          'https://alice:webdav-secret@example.test/dav/private?sign=query-secret',
      username: 'alice',
      password: 'webdav-secret',
      defaultDirectory: '私人/影片',
      openListRecovery: OpenListRecoveryConfig(
        enabled: true,
        baseUrl: 'https://admin:openlist-secret@example.test/admin?token=q',
        username: 'admin',
        password: 'openlist-secret',
        token: 'openlist-token',
      ),
      openListIndex: OpenListIndexConfig(userToken: 'openlist-user-token'),
    );
    await configStore.save(StreamPathConfig.defaults().upsertProfile(profile));
    final progress = await PlaybackProgressService.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(progress.close);
    final service = DiagnosticService(
      configStore: configStore,
      progressService: progress,
      directoryCache: DirectoryCache(),
      playerService: ExternalPlayerService(
        configStore: configStore,
        progressService: progress,
      ),
      dataDirectoryProvider: () async => tempDir,
      now: () => DateTime.utc(2026, 8, 22, 8, 30),
    );
    final snapshot = DiagnosticSnapshot(
      createdAt: DateTime.utc(2026, 8, 22, 8, 30),
      items: const [
        DiagnosticItem(
          id: 'attack',
          label: '攻击样本',
          status: DiagnosticStatus.failed,
          summary:
              'https://user:pass@example.test/private?a=1 password=webdav-secret',
          details: {
            'nested': ['openlist-token', 'Bearer hidden-token'],
          },
        ),
      ],
    );

    final file = await service.export(snapshot);
    final repeatedFile = await service.export(snapshot);
    final body = await file.readAsString();

    for (final forbidden in [
      'webdav-secret',
      'openlist-secret',
      'openlist-token',
      'openlist-user-token',
      'hidden-token',
      'user:pass',
      'query-secret',
      '私人/影片',
      '可能含敏感信息的名称',
    ]) {
      expect(body, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(body, contains('https://example.test'));
    expect(body, contains('pathHash'));
    expect(repeatedFile.path, isNot(file.path));
    expect(repeatedFile.existsSync(), isTrue);
  });
}
