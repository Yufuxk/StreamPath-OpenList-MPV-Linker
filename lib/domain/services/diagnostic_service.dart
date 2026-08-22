import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/app_paths.dart';
import '../../data/local/directory_cache.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/local/stream_path_config_store.dart';
import '../../data/models/server_profile.dart';
import '../../data/models/stream_path_config.dart';
import 'external_player_service.dart';
import 'openlist_api_client.dart';
import 'openlist_recovery_service.dart';
import 'webdav_service.dart';

enum DiagnosticStatus { passed, warning, failed, skipped }

class DiagnosticItem {
  const DiagnosticItem({
    required this.id,
    required this.label,
    required this.status,
    required this.summary,
    this.details = const {},
  });

  final String id;
  final String label;
  final DiagnosticStatus status;
  final String summary;
  final Map<String, Object?> details;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'status': status.name,
    'summary': summary,
    if (details.isNotEmpty) 'details': details,
  };
}

class DiagnosticSnapshot {
  const DiagnosticSnapshot({required this.createdAt, required this.items});

  final DateTime createdAt;
  final List<DiagnosticItem> items;

  bool get hasFailures =>
      items.any((item) => item.status == DiagnosticStatus.failed);
}

/// 把公开设置响应按 OpenList/AList 官方 envelope 转成诊断项。
DiagnosticItem diagnoseOpenListSettingsResponse(
  OpenListHttpResponse response, {
  required String baseUrl,
}) {
  final envelope = OpenListEnvelope.parse(response);
  final status = response.statusCode ?? 0;
  final validEnvelope =
      status >= 200 &&
      status < 300 &&
      envelope.payload != null &&
      envelope.code == 200;
  return DiagnosticItem(
    id: 'openlist-api',
    label: 'OpenList/AList API',
    status: validEnvelope ? DiagnosticStatus.passed : DiagnosticStatus.failed,
    summary: validEnvelope
        ? '公开设置接口可访问'
        : envelope.payload == null && status >= 200 && status < 300
        ? '公开设置接口未返回 OpenList/AList JSON envelope'
        : envelope.code != null && envelope.code != 200
        ? '公开设置接口返回 code ${envelope.code}：${envelope.message}'
        : '公开设置接口返回 HTTP $status',
    details: diagnosticUrlDescriptor(baseUrl),
  );
}

/// 运行只读健康检查并导出不含凭据的 JSON 诊断包。
class DiagnosticService {
  DiagnosticService({
    required this.configStore,
    required this.progressService,
    required this.directoryCache,
    required this.playerService,
    this.audioProgressService,
    this.webDavService,
    Dio? dio,
    OpenListApiClient? openListApiClient,
    Future<Directory> Function()? dataDirectoryProvider,
    DateTime Function()? now,
  }) : _openListApi = openListApiClient ?? OpenListApiClient(dio: dio ?? Dio()),
       _dataDirectoryProvider = dataDirectoryProvider ?? AppPaths.dataDirectory,
       _now = now ?? DateTime.now;

  final StreamPathConfigStore configStore;
  final PlaybackProgressService progressService;
  final PlaybackProgressService? audioProgressService;
  final DirectoryCache directoryCache;
  final ExternalPlayerService playerService;
  final WebDAVService? webDavService;
  final OpenListApiClient _openListApi;
  final Future<Directory> Function() _dataDirectoryProvider;
  final DateTime Function() _now;

  Future<DiagnosticSnapshot> run() async {
    final items = <DiagnosticItem>[];
    items.add(await _checkWebDav());
    items.add(await _checkPlayer());
    items.add(await _checkMpvIpc());
    items.add(await _checkOpenList());
    items.add(await _checkDataDirectory());
    items.add(
      await _checkDatabase('sqlite.video', '视频 SQLite', progressService),
    );
    final audio = audioProgressService;
    items.add(
      audio == null
          ? const DiagnosticItem(
              id: 'sqlite.audio',
              label: '音频 SQLite',
              status: DiagnosticStatus.warning,
              summary: '音频进度数据库未初始化',
            )
          : await _checkDatabase('sqlite.audio', '音频 SQLite', audio),
    );
    final cache = directoryCache.diagnostics();
    items.add(
      DiagnosticItem(
        id: 'directory-cache',
        label: '目录缓存',
        status: cache.initialized
            ? DiagnosticStatus.passed
            : DiagnosticStatus.failed,
        summary: cache.initialized ? 'Hive 已打开' : 'Hive 尚未初始化',
        details: {'entryCount': cache.entryCount},
      ),
    );
    items.add(await _checkConfigReliability());
    return DiagnosticSnapshot(createdAt: _now(), items: items);
  }

  Future<File> export(DiagnosticSnapshot snapshot) async {
    final dataDir = await _dataDirectoryProvider();
    final outputDir = Directory(p.join(dataDir.path, 'diagnostics'));
    await outputDir.create(recursive: true);
    final stamp = snapshot.createdAt
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    var output = File(
      p.join(outputDir.path, 'streampath-diagnostics-$stamp.json'),
    );
    for (var suffix = 1; await output.exists(); suffix++) {
      output = File(
        p.join(outputDir.path, 'streampath-diagnostics-$stamp-$suffix.json'),
      );
    }
    final config = configStore.current;
    final migrations = await configStore.migrationHistory();
    final bundle = <String, Object?>{
      'bundleVersion': 1,
      'createdAt': snapshot.createdAt.toUtc().toIso8601String(),
      'platform': {
        'operatingSystem': Platform.operatingSystem,
        'operatingSystemVersion': redactDiagnosticText(
          Platform.operatingSystemVersion,
        ),
      },
      'configuration': {
        'schemaVersion': config.schemaVersion,
        'credentialStorageMode': config.credentialStorageMode.jsonValue,
        'activeProfileIdHash': _digest(config.profileId),
        'profiles': [
          for (final profile in config.profiles)
            {
              'profileIdHash': _digest(profile.profileId),
              'server': diagnosticUrlDescriptor(profile.serverUrl),
              'defaultDirectoryHash': _digest(profile.defaultDirectory),
              'openListEnabled': profile.openListRecovery.enabled,
              'openListServer': diagnosticUrlDescriptor(
                profile.openListRecovery.baseUrl,
              ),
              'hasWebDavPassword': profile.password.isNotEmpty,
              'hasOpenListCredential': profile.openListRecovery.hasCredentials,
            },
        ],
        'missingCredentialProfileCount':
            configStore.missingCredentialProfileIds.length,
      },
      'migrations': [
        for (final migration in migrations)
          {
            'timestamp': migration.timestamp.toUtc().toIso8601String(),
            'fromVersion': migration.fromVersion,
            'toVersion': migration.toVersion,
            'success': migration.success,
            'backupFile': p.basename(migration.backupPath),
            if (migration.message != null)
              'message': redactDiagnosticText(migration.message!),
          },
      ],
      'checks': [
        for (final item in snapshot.items)
          {
            ...item.toJson(),
            'summary': redactDiagnosticText(
              item.summary,
              secrets: _knownSecrets(config),
            ),
            if (item.details.isNotEmpty)
              'details': _redactDiagnosticValue(
                item.details,
                secrets: _knownSecrets(config),
              ),
          },
      ],
    };
    final body = const JsonEncoder.withIndent('  ').convert(bundle);
    final temp = File('${output.path}.tmp');
    await temp.writeAsString(body, flush: true);
    await temp.rename(output.path);
    return output;
  }

  Future<DiagnosticItem> _checkWebDav() async {
    final service = webDavService;
    if (service == null) {
      return const DiagnosticItem(
        id: 'webdav',
        label: 'WebDAV',
        status: DiagnosticStatus.skipped,
        summary: '当前未连接，未执行网络检查',
      );
    }
    try {
      await service.verifyConnection().timeout(const Duration(seconds: 10));
      return DiagnosticItem(
        id: 'webdav',
        label: 'WebDAV',
        status: DiagnosticStatus.passed,
        summary: '根目录认证请求成功',
        details: diagnosticUrlDescriptor(service.baseUrl),
      );
    } catch (error) {
      return DiagnosticItem(
        id: 'webdav',
        label: 'WebDAV',
        status: DiagnosticStatus.failed,
        summary:
            '认证或网络请求失败：${redactDiagnosticText(error.toString(), secrets: _knownSecrets(configStore.current))}',
      );
    }
  }

  Future<DiagnosticItem> _checkPlayer() async {
    final config = configStore.current.toPlayerConfig();
    final issue = playerService.validateExecutable(config);
    if (issue != null) {
      return DiagnosticItem(
        id: 'player',
        label: '播放器路径',
        status: DiagnosticStatus.failed,
        summary: issue.startsWith('文件不存在') ? '播放器文件不存在' : issue,
      );
    }
    final executable = config.executable.trim();
    if (executable.contains('\\') || executable.contains('/')) {
      return const DiagnosticItem(
        id: 'player',
        label: '播放器路径',
        status: DiagnosticStatus.passed,
        summary: '播放器文件存在',
      );
    }
    try {
      final result = await Process.run(
        Platform.isWindows ? 'where.exe' : 'which',
        [executable],
      ).timeout(const Duration(seconds: 3));
      return DiagnosticItem(
        id: 'player',
        label: '播放器路径',
        status: result.exitCode == 0
            ? DiagnosticStatus.passed
            : DiagnosticStatus.failed,
        summary: result.exitCode == 0 ? '播放器可从 PATH 解析' : 'PATH 中未找到播放器',
      );
    } catch (_) {
      return const DiagnosticItem(
        id: 'player',
        label: '播放器路径',
        status: DiagnosticStatus.warning,
        summary: '无法完成 PATH 解析检查',
      );
    }
  }

  Future<DiagnosticItem> _checkMpvIpc() async {
    final result = await playerService.diagnoseMpvIpc();
    if (result == null) {
      return const DiagnosticItem(
        id: 'mpv-ipc',
        label: 'MPV IPC',
        status: DiagnosticStatus.skipped,
        summary: '没有活动 MPV 会话',
      );
    }
    return DiagnosticItem(
      id: 'mpv-ipc',
      label: 'MPV IPC',
      status: result ? DiagnosticStatus.passed : DiagnosticStatus.failed,
      summary: result ? '只读属性查询成功' : '活动会话的 IPC 查询失败',
    );
  }

  Future<DiagnosticItem> _checkOpenList() async {
    final recovery = configStore.current.openListRecovery;
    if (!recovery.enabled) {
      return const DiagnosticItem(
        id: 'openlist-api',
        label: 'OpenList/AList API',
        status: DiagnosticStatus.skipped,
        summary: '自动恢复未启用',
      );
    }
    final base = OpenListRecoveryService.normalizeBaseUri(recovery.baseUrl);
    if (base == null) {
      return const DiagnosticItem(
        id: 'openlist-api',
        label: 'OpenList/AList API',
        status: DiagnosticStatus.failed,
        summary: '后台地址无效',
      );
    }
    final endpoint = Uri.parse(
      '${base.toString().replaceAll(RegExp(r'/+$'), '')}/api/public/settings',
    );
    try {
      final response = await _openListApi.request(
        endpoint,
        method: 'GET',
        timeout: const Duration(seconds: 7),
      );
      return diagnoseOpenListSettingsResponse(
        response,
        baseUrl: recovery.baseUrl,
      );
    } catch (error) {
      return DiagnosticItem(
        id: 'openlist-api',
        label: 'OpenList/AList API',
        status: DiagnosticStatus.failed,
        summary:
            '公开设置接口请求失败：${redactDiagnosticText(error.toString(), secrets: _knownSecrets(configStore.current))}',
      );
    }
  }

  Future<DiagnosticItem> _checkDataDirectory() async {
    File? probe;
    try {
      final dataDir = await _dataDirectoryProvider();
      final directory = Directory(p.join(dataDir.path, 'diagnostics'));
      await directory.create(recursive: true);
      probe = File(
        p.join(directory.path, '.write-check-${_now().microsecondsSinceEpoch}'),
      );
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return const DiagnosticItem(
        id: 'data-directory',
        label: '数据目录写入',
        status: DiagnosticStatus.passed,
        summary: '创建、刷新与删除测试文件成功',
      );
    } catch (error) {
      try {
        if (probe != null && await probe.exists()) await probe.delete();
      } catch (_) {}
      return DiagnosticItem(
        id: 'data-directory',
        label: '数据目录写入',
        status: DiagnosticStatus.failed,
        summary: '写入检查失败：${redactDiagnosticText(error.toString())}',
      );
    }
  }

  Future<DiagnosticItem> _checkDatabase(
    String id,
    String label,
    PlaybackProgressService service,
  ) async {
    try {
      final report = await service.checkIntegrity();
      return DiagnosticItem(
        id: id,
        label: label,
        status: report.ok ? DiagnosticStatus.passed : DiagnosticStatus.failed,
        summary: report.ok ? 'PRAGMA quick_check 通过' : '完整性检查报告异常',
        details: {'messages': report.messages.take(10).toList()},
      );
    } catch (error) {
      return DiagnosticItem(
        id: id,
        label: label,
        status: DiagnosticStatus.failed,
        summary: redactDiagnosticText(error.toString()),
      );
    }
  }

  Future<DiagnosticItem> _checkConfigReliability() async {
    final config = configStore.current;
    final migrations = await configStore.migrationHistory();
    final missing = configStore.missingCredentialProfileIds.length;
    final failedMigration = migrations.reversed
        .where((record) => !record.success)
        .firstOrNull;
    final failed =
        config.schemaVersion != StreamPathConfig.currentSchemaVersion ||
        failedMigration != null ||
        missing > 0 ||
        configStore.lastLoadIssue != null ||
        configStore.futureSchemaDetected;
    return DiagnosticItem(
      id: 'configuration',
      label: '配置与迁移',
      status: failed ? DiagnosticStatus.failed : DiagnosticStatus.passed,
      summary: failed ? '配置版本、迁移记录或凭据存在异常' : '配置版本有效，迁移与凭据状态正常',
      details: {
        'schemaVersion': config.schemaVersion,
        'migrationCount': migrations.length,
        'missingCredentialProfileCount': missing,
        'hasLoadIssue': configStore.lastLoadIssue != null,
        'futureSchemaDetected': configStore.futureSchemaDetected,
        'hasRollbackBackup': migrations.any(
          (record) =>
              record.success &&
              FileSystemEntity.typeSync(record.backupPath) !=
                  FileSystemEntityType.notFound,
        ),
      },
    );
  }

  static List<String> _knownSecrets(StreamPathConfig config) => [
    for (final profile in config.profiles) ...[
      profile.password,
      profile.openListRecovery.password,
      profile.openListRecovery.token,
      profile.openListIndex.userToken,
    ],
  ].where((value) => value.isNotEmpty).toList();
}

Map<String, Object?> diagnosticUrlDescriptor(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      !uri.hasScheme ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return {'valid': false, 'valueHash': _digest(raw)};
  }
  final defaultPort =
      (uri.scheme == 'http' && uri.port == 80) ||
      (uri.scheme == 'https' && uri.port == 443);
  final origin = Uri(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    port: defaultPort ? null : uri.port,
  ).origin;
  return {'valid': true, 'origin': origin, 'pathHash': _digest(uri.path)};
}

String redactDiagnosticText(
  String value, {
  Iterable<String> secrets = const [],
}) {
  var result = value;
  // URL 必须先整体替换；若先替换一字符密码，可能把 URL 截断并让后半段
  // userinfo 或签名查询逃过后续匹配。
  result = result.replaceAllMapped(RegExp(r'''https?://[^\s<>"']+'''), (match) {
    final descriptor = diagnosticUrlDescriptor(match.group(0)!);
    return '[URL ${descriptor['origin'] ?? 'invalid'} '
        '${descriptor['pathHash'] ?? descriptor['valueHash']}]';
  });
  final orderedSecrets =
      secrets.where((secret) => secret.isNotEmpty).toSet().toList()
        ..sort((left, right) => right.length.compareTo(left.length));
  for (final secret in orderedSecrets) {
    result = result.replaceAll(secret, '[REDACTED]');
  }
  result = result.replaceAll(
    RegExp(r'\b(?:basic|bearer)\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    '[REDACTED_AUTH]',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'\b(password|token|authorization)\s*[:=]\s*[^\s,;]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}=[REDACTED]',
  );
  return result;
}

Object? _redactDiagnosticValue(
  Object? value, {
  required Iterable<String> secrets,
}) {
  if (value is String) return redactDiagnosticText(value, secrets: secrets);
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): _redactDiagnosticValue(
          entry.value,
          secrets: secrets,
        ),
    };
  }
  if (value is Iterable) {
    return [
      for (final item in value) _redactDiagnosticValue(item, secrets: secrets),
    ];
  }
  return value;
}

String _digest(String value) =>
    'sha256:${sha256.convert(utf8.encode(value)).toString()}';
