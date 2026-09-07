import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/web_dav_file.dart';
import 'iso_bridge_client.dart';
import 'player_process_controller.dart';
import 'webdav_service.dart';

String isoBridgePlaybackErrorMessage(String code) => switch (code) {
  'remote_changed' => '远端 ISO 在播放期间发生变化',
  'invalid_disc' => '没有解析到可播放的 Blu-ray Title/MPLS',
  'network_error' => 'ISO Bridge 远端读取失败',
  'winfsp_unavailable' => '请先安装随附的 WinFsp 运行时，再使用远程蓝光菜单',
  _ => 'ISO Bridge 启动失败',
};

@immutable
class IsoBridgeChapter {
  const IsoBridgeChapter({
    required this.start,
    required this.duration,
    this.name,
  });

  final Duration start;
  final Duration duration;
  final String? name;
}

@immutable
class IsoBridgeTitle {
  const IsoBridgeTitle({
    required this.titleIndex,
    required this.mplsId,
    required this.duration,
    required this.streamSize,
    required this.chapters,
  });

  final int titleIndex;
  final String mplsId;
  final Duration duration;
  final int streamSize;
  final List<IsoBridgeChapter> chapters;
}

@visibleForTesting
@immutable
class IsoBridgeReady {
  const IsoBridgeReady({
    required this.port,
    required this.token,
    required this.totalBytes,
    required this.titles,
    this.discPath,
  });

  final int port;
  final String token;
  final int totalBytes;
  final List<IsoBridgeTitle> titles;
  final String? discPath;

  factory IsoBridgeReady.fromMessage(
    Map<String, dynamic> message, {
    bool remoteMenu = false,
    String? mountedSessionPath,
  }) {
    final port = (message['port'] as num?)?.toInt();
    final token = message['token'];
    final totalBytes = (message['totalBytes'] as num?)?.toInt();
    final rawTitles = message['titles'];
    if (message['type'] != 'ready' ||
        message['version'] != 1 ||
        port == null ||
        (mountedSessionPath == null ? port <= 0 : port != 0) ||
        port > 65535 ||
        token is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(token) ||
        totalBytes == null ||
        totalBytes <= 0 ||
        rawTitles is! List) {
      throw const IsoBridgeProtocolException('ISO Bridge ready 响应无效');
    }
    final titles = <IsoBridgeTitle>[];
    final seen = <String>{};
    for (final rawTitle in rawTitles) {
      if (rawTitle is! Map) {
        throw const IsoBridgeProtocolException('ISO Bridge Title 响应无效');
      }
      final titleIndex = (rawTitle['titleIndex'] as num?)?.toInt();
      final mplsId = rawTitle['mplsId'];
      final durationMs = (rawTitle['durationMs'] as num?)?.toInt();
      final streamSize = (rawTitle['size'] as num?)?.toInt();
      final rawChapters = rawTitle['chapters'];
      if (titleIndex == null ||
          titleIndex < 0 ||
          mplsId is! String ||
          !RegExp(r'^\d{5}$').hasMatch(mplsId) ||
          !seen.add(mplsId) ||
          durationMs == null ||
          durationMs <= 0 ||
          streamSize == null ||
          streamSize <= 0 ||
          rawChapters is! List) {
        throw const IsoBridgeProtocolException('ISO Bridge Title 响应无效');
      }
      final chapters = <IsoBridgeChapter>[];
      for (final rawChapter in rawChapters) {
        if (rawChapter is! Map) {
          throw const IsoBridgeProtocolException('ISO Bridge 章节响应无效');
        }
        final startMs = (rawChapter['startMs'] as num?)?.toInt();
        final chapterDurationMs = (rawChapter['durationMs'] as num?)?.toInt();
        final name = rawChapter['name'];
        if (startMs == null ||
            startMs < 0 ||
            chapterDurationMs == null ||
            chapterDurationMs < 0 ||
            (name != null && name is! String)) {
          throw const IsoBridgeProtocolException('ISO Bridge 章节响应无效');
        }
        chapters.add(
          IsoBridgeChapter(
            start: Duration(milliseconds: startMs),
            duration: Duration(milliseconds: chapterDurationMs),
            name: name as String?,
          ),
        );
      }
      titles.add(
        IsoBridgeTitle(
          titleIndex: titleIndex,
          mplsId: mplsId,
          duration: Duration(milliseconds: durationMs),
          streamSize: streamSize,
          chapters: List<IsoBridgeChapter>.unmodifiable(chapters),
        ),
      );
    }
    if (remoteMenu &&
        (mountedSessionPath == null ||
            message['capability'] != 'winfsp-disc-v1' ||
            message['mode'] != 'hdmv' ||
            totalBytes % 2048 != 0 ||
            titles.isNotEmpty)) {
      throw const IsoBridgeProtocolException('远程蓝光菜单能力响应无效');
    }
    if (mountedSessionPath != null &&
        (!remoteMenu ||
            message['discPath'] !=
                p.join(mountedSessionPath, 'disc', 'disc.iso'))) {
      throw const IsoBridgeProtocolException('远程蓝光菜单能力响应无效');
    }
    if (!remoteMenu && titles.isEmpty) {
      throw const IsoBridgeProtocolException('ISO Bridge 未返回可播放 Title');
    }
    return IsoBridgeReady(
      port: port,
      token: token,
      totalBytes: totalBytes,
      titles: List<IsoBridgeTitle>.unmodifiable(titles),
      discPath: mountedSessionPath == null
          ? null
          : message['discPath'] as String,
    );
  }
}

/// ISO Bridge 指标快照；缺失字段保持为 null，避免旧版数据被解释为零耗时。
@immutable
class IsoBridgeMetricsSnapshot {
  const IsoBridgeMetricsSnapshot({
    required this.version,
    this.remoteBodyBytes,
    this.remoteTransferActiveMicroseconds,
    this.remoteTransferWallClockMicroseconds,
    this.concurrentTransferWallClockMicroseconds,
    this.responseBodyActiveMicroseconds,
    this.firstMediaResponseReadyMicroseconds,
    this.finalSnapshot,
    this.lastErrorCode,
    this.mediaFailureCount,
    this.lastMediaFailureSequence,
    this.lastMediaFailureGeneration,
    this.lastMediaFailureStatusCategory,
    this.terminalRejectedMediaGetCount,
    this.structureCacheHit,
    this.requestContextCreatedCount,
    this.requestContextClosedCount,
    this.requestContextLive,
    this.requestContextPeak,
    this.timeSeekRedirectEnabled,
    this.demandBlockBytes,
    this.prefetchActivePeak,
    this.prefetchOverlapCount,
    this.prefetchPendingGapMicrosecondsTotal,
    this.prefetchPendingGapMicrosecondsMax,
    this.prefetchInFlightBytesPeak,
    this.prefetchHitBytes,
    this.prefetchConcurrentWallClockMicroseconds,
    this.metadataNetwork,
    this.playbackNetwork,
    this.metadataCache,
    this.playbackCache,
    this.errorTypes = const [],
  });

  final int version;
  final int? remoteBodyBytes;
  final int? remoteTransferActiveMicroseconds;
  final int? remoteTransferWallClockMicroseconds;
  final int? concurrentTransferWallClockMicroseconds;
  final int? responseBodyActiveMicroseconds;
  final int? firstMediaResponseReadyMicroseconds;
  final bool? finalSnapshot;
  final String? lastErrorCode;
  final int? mediaFailureCount;
  final int? lastMediaFailureSequence;
  final int? lastMediaFailureGeneration;
  final String? lastMediaFailureStatusCategory;
  final int? terminalRejectedMediaGetCount;
  final bool? structureCacheHit;
  final int? requestContextCreatedCount;
  final int? requestContextClosedCount;
  final int? requestContextLive;
  final int? requestContextPeak;
  final bool? timeSeekRedirectEnabled;
  final int? demandBlockBytes;
  final int? prefetchActivePeak;
  final int? prefetchOverlapCount;
  final int? prefetchPendingGapMicrosecondsTotal;
  final int? prefetchPendingGapMicrosecondsMax;
  final int? prefetchInFlightBytesPeak;
  final int? prefetchHitBytes;
  final int? prefetchConcurrentWallClockMicroseconds;
  final IsoBridgeNetworkPhaseMetricsSnapshot? metadataNetwork;
  final IsoBridgeNetworkPhaseMetricsSnapshot? playbackNetwork;
  final IsoBridgeCachePhaseMetricsSnapshot? metadataCache;
  final IsoBridgeCachePhaseMetricsSnapshot? playbackCache;
  final List<String> errorTypes;

  static IsoBridgeMetricsSnapshot? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final version = (value['version'] as num?)?.toInt();
    if (version != 1 && version != 2) return null;
    if (version == 1) {
      return IsoBridgeMetricsSnapshot(
        version: version!,
        remoteBodyBytes: _nonNegativeInt(value['remoteTransferBytes']),
        remoteTransferActiveMicroseconds: _nonNegativeInt(
          value['remoteTransferActiveMicroseconds'],
        ),
        errorTypes: _errorTypes(value['errors']),
      );
    }
    final network = value['network'];
    final cache = value['cache'];
    final bridge = value['bridge'];
    final bluray = value['bluray'];
    return IsoBridgeMetricsSnapshot(
      version: version!,
      remoteBodyBytes: network is Map<String, dynamic>
          ? _nonNegativeInt(network['remoteBodyBytes'])
          : null,
      remoteTransferActiveMicroseconds: _nonNegativeInt(
        value['remoteTransferActiveMicroseconds'],
      ),
      remoteTransferWallClockMicroseconds: network is Map<String, dynamic>
          ? _nonNegativeInt(network['remoteTransferWallClockUs'])
          : null,
      concurrentTransferWallClockMicroseconds: network is Map<String, dynamic>
          ? _nonNegativeInt(network['concurrentTransferWallClockUs'])
          : null,
      responseBodyActiveMicroseconds: network is Map<String, dynamic>
          ? _nonNegativeInt(network['responseBodyActiveUsTotal'])
          : null,
      firstMediaResponseReadyMicroseconds: bridge is Map<String, dynamic>
          ? _nonNegativeInt(bridge['firstMediaResponseReadyUs'])
          : null,
      finalSnapshot: bridge is Map<String, dynamic> && bridge['final'] is bool
          ? bridge['final'] as bool
          : null,
      lastErrorCode: value['lastErrorCode'] is String
          ? value['lastErrorCode'] as String
          : null,
      mediaFailureCount: bluray is Map<String, dynamic>
          ? _nonNegativeInt(bluray['mediaFailureCount'])
          : null,
      lastMediaFailureSequence: bluray is Map<String, dynamic>
          ? _nonNegativeInt(bluray['lastMediaFailureSequence'])
          : null,
      lastMediaFailureGeneration: bluray is Map<String, dynamic>
          ? _nonNegativeInt(bluray['lastMediaFailureGeneration'])
          : null,
      lastMediaFailureStatusCategory:
          bluray is Map<String, dynamic> &&
              bluray['lastMediaFailureStatusCategory'] is String
          ? bluray['lastMediaFailureStatusCategory'] as String
          : null,
      terminalRejectedMediaGetCount: bluray is Map<String, dynamic>
          ? _nonNegativeInt(bluray['terminalRejectedMediaGetCount'])
          : null,
      structureCacheHit:
          bluray is Map<String, dynamic> && bluray['structureCacheHit'] is bool
          ? bluray['structureCacheHit'] as bool
          : null,
      requestContextCreatedCount: network is Map<String, dynamic>
          ? _nonNegativeInt(network['requestContextCreatedCount'])
          : null,
      requestContextClosedCount: network is Map<String, dynamic>
          ? _nonNegativeInt(network['requestContextClosedCount'])
          : null,
      requestContextLive: network is Map<String, dynamic>
          ? _nonNegativeInt(network['requestContextLive'])
          : null,
      requestContextPeak: network is Map<String, dynamic>
          ? _nonNegativeInt(network['requestContextPeak'])
          : null,
      timeSeekRedirectEnabled:
          bridge is Map<String, dynamic> &&
              bridge['timeSeekRedirectEnabled'] is bool
          ? bridge['timeSeekRedirectEnabled'] as bool
          : null,
      demandBlockBytes: bridge is Map<String, dynamic>
          ? _nonNegativeInt(bridge['demandBlockBytes'])
          : null,
      prefetchActivePeak: cache is Map<String, dynamic>
          ? _nonNegativeInt(cache['prefetchActivePeak'])
          : null,
      prefetchOverlapCount: cache is Map<String, dynamic>
          ? _nonNegativeInt(cache['prefetchOverlapCount'])
          : null,
      prefetchPendingGapMicrosecondsTotal: cache is Map<String, dynamic>
          ? _nonNegativeInt(cache['prefetchPendingGapUsTotal'])
          : null,
      prefetchPendingGapMicrosecondsMax: cache is Map<String, dynamic>
          ? _nonNegativeInt(cache['prefetchPendingGapUsMax'])
          : null,
      prefetchInFlightBytesPeak: cache is Map<String, dynamic>
          ? _nonNegativeInt(cache['prefetchInFlightBytesPeak'])
          : null,
      prefetchHitBytes: cache is Map<String, dynamic>
          ? _nonNegativeInt(cache['prefetchHitBytes'])
          : null,
      prefetchConcurrentWallClockMicroseconds: cache is Map<String, dynamic>
          ? _nonNegativeInt(cache['prefetchConcurrentWallClockUs'])
          : null,
      metadataNetwork: IsoBridgeNetworkPhaseMetricsSnapshot.tryParse(
        value['metadataNetwork'],
      ),
      playbackNetwork: IsoBridgeNetworkPhaseMetricsSnapshot.tryParse(
        value['playbackNetwork'],
      ),
      metadataCache: IsoBridgeCachePhaseMetricsSnapshot.tryParse(
        value['metadataCache'],
      ),
      playbackCache: IsoBridgeCachePhaseMetricsSnapshot.tryParse(
        value['playbackCache'],
      ),
      errorTypes: _errorTypes(value['errors']),
    );
  }

  static int? _nonNegativeInt(Object? value) {
    final result = (value as num?)?.toInt();
    return result == null || result < 0 ? null : result;
  }

  static List<String> _errorTypes(Object? value) {
    if (value is! List) return const [];
    return List<String>.unmodifiable(
      value
          .whereType<Map>()
          .map((entry) => entry['error-type'])
          .whereType<String>(),
    );
  }
}

@immutable
class IsoBridgeNetworkPhaseMetricsSnapshot {
  const IsoBridgeNetworkPhaseMetricsSnapshot({
    this.requestCount,
    this.redirectCount,
    this.responseHeaderLatencyMicroseconds,
    this.responseBodyActiveMicroseconds,
    this.remoteBodyBytes,
    this.remoteTransferWallClockMicroseconds,
    this.concurrentTransferWallClockMicroseconds,
    this.requestContextCreatedCount,
    this.requestContextClosedCount,
  });

  final int? requestCount;
  final int? redirectCount;
  final int? responseHeaderLatencyMicroseconds;
  final int? responseBodyActiveMicroseconds;
  final int? remoteBodyBytes;
  final int? remoteTransferWallClockMicroseconds;
  final int? concurrentTransferWallClockMicroseconds;
  final int? requestContextCreatedCount;
  final int? requestContextClosedCount;

  static IsoBridgeNetworkPhaseMetricsSnapshot? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    return IsoBridgeNetworkPhaseMetricsSnapshot(
      requestCount: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['requestCount'],
      ),
      redirectCount: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['redirectCount'],
      ),
      responseHeaderLatencyMicroseconds:
          IsoBridgeMetricsSnapshot._nonNegativeInt(
            value['responseHeaderLatencyUsTotal'],
          ),
      responseBodyActiveMicroseconds: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['responseBodyActiveUsTotal'],
      ),
      remoteBodyBytes: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['remoteBodyBytes'],
      ),
      remoteTransferWallClockMicroseconds:
          IsoBridgeMetricsSnapshot._nonNegativeInt(
            value['remoteTransferWallClockUs'],
          ),
      concurrentTransferWallClockMicroseconds:
          IsoBridgeMetricsSnapshot._nonNegativeInt(
            value['concurrentTransferWallClockUs'],
          ),
      requestContextCreatedCount: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['requestContextCreatedCount'],
      ),
      requestContextClosedCount: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['requestContextClosedCount'],
      ),
    );
  }
}

@immutable
class IsoBridgeCachePhaseMetricsSnapshot {
  const IsoBridgeCachePhaseMetricsSnapshot({
    this.requestCount,
    this.foregroundFetchBytes,
    this.consumerBytesDelivered,
    this.cacheHitCount,
    this.cacheMissCount,
    this.evictionCount,
    this.refetchCount,
    this.residentBytes,
    this.capacityBytes,
    this.configuredPrefetchBlocks,
    this.blockBytes,
    this.retainedBytes,
  });

  final int? requestCount;
  final int? foregroundFetchBytes;
  final int? consumerBytesDelivered;
  final int? cacheHitCount;
  final int? cacheMissCount;
  final int? evictionCount;
  final int? refetchCount;
  final int? residentBytes;
  final int? capacityBytes;
  final int? configuredPrefetchBlocks;
  final int? blockBytes;
  final int? retainedBytes;

  static IsoBridgeCachePhaseMetricsSnapshot? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    return IsoBridgeCachePhaseMetricsSnapshot(
      requestCount: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['requestCount'],
      ),
      foregroundFetchBytes: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['foregroundFetchBytes'],
      ),
      consumerBytesDelivered: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['consumerBytesDelivered'],
      ),
      cacheHitCount: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['cacheHitCount'],
      ),
      cacheMissCount: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['cacheMissCount'],
      ),
      evictionCount: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['evictionCount'],
      ),
      refetchCount: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['refetchCount'],
      ),
      residentBytes: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['residentBytes'],
      ),
      capacityBytes: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['capacityBytes'],
      ),
      configuredPrefetchBlocks: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['configuredPrefetchBlocks'],
      ),
      blockBytes: IsoBridgeMetricsSnapshot._nonNegativeInt(value['blockBytes']),
      retainedBytes: IsoBridgeMetricsSnapshot._nonNegativeInt(
        value['retainedBytes'],
      ),
    );
  }
}

abstract interface class IsoAccessProvider {
  Future<IsoAccessHandle> prepare({
    required WebDAVService webDavService,
    required WebDavFile file,
    required Directory sessionDirectory,
    required String structureCachePath,
    void Function(IsoAccessPhase phase)? onPhase,
    Future<void> Function(PlayerProcessIdentity identity)? onHelperStarted,
  });

  void cancel();
}

enum IsoAccessPhase { startingBridge, probingStream, parsingTitles }

abstract interface class IsoAccessHandle {
  Directory get sessionDirectory;
  PlayerProcessIdentity get helperIdentity;
  int get totalBytes;
  List<IsoBridgeTitle> get titles;

  Uri playbackUri(String mplsId);
  Future<void> configureCache({
    required int blockCount,
    required int prefetchBlocks,
    int? cacheSecs,
  });
  Future<void> attachPlayer(int pid);
  Future<void> cleanup();
}

abstract interface class RemoteDiscAccessHandle implements IsoAccessHandle {
  Uri get discUri;
}

class LoopbackIsoAccessHandle implements RemoteDiscAccessHandle {
  LoopbackIsoAccessHandle({
    required this.sessionDirectory,
    required this.helperIdentity,
    required this.totalBytes,
    required this.titles,
    required this._port,
    required this._token,
    required this._client,
    required this._helperProcess,
    this.remoteMenu = false,
    this.discPath,
  });

  @override
  final Directory sessionDirectory;
  @override
  final PlayerProcessIdentity helperIdentity;
  @override
  final int totalBytes;
  @override
  final List<IsoBridgeTitle> titles;
  final int _port;
  final String _token;
  final IsoBridgeClient _client;
  final Process _helperProcess;
  final bool remoteMenu;
  final String? discPath;
  bool _attached = false;
  bool _cleaned = false;

  int get helperPid => helperIdentity.pid;

  @override
  Uri get discUri {
    if (!remoteMenu || discPath == null) {
      throw StateError('Not a mounted remote disc session');
    }
    return Uri.file(discPath!, windows: true);
  }

  @override
  Uri playbackUri(String mplsId) {
    if (!RegExp(r'^\d{5}$').hasMatch(mplsId) ||
        !titles.any((title) => title.mplsId == mplsId)) {
      throw AppException.config('Blu-ray Title 选择结果无效');
    }
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _port,
      pathSegments: [_token, 'title', '$mplsId.m2ts'],
    );
  }

  @override
  Future<void> configureCache({
    required int blockCount,
    required int prefetchBlocks,
    int? cacheSecs,
  }) async {
    if (_cleaned || _attached) {
      throw AppException.process('ISO Bridge 缓存配置状态无效');
    }
    await _client.send({
      'type': 'configure_cache',
      'blockCount': blockCount,
      'prefetchBlocks': prefetchBlocks,
      'cacheSecs': ?cacheSecs,
    });
    final response = await _client.receive(timeout: const Duration(seconds: 5));
    if (response['type'] != 'ready' || response['configured'] != true) {
      throw AppException.process('ISO Bridge 未确认缓存配置');
    }
  }

  @override
  Future<void> attachPlayer(int pid) async {
    if (_cleaned || _attached || pid <= 0) {
      throw AppException.process('ISO Bridge 播放器绑定状态无效');
    }
    await _client.send({'type': 'attachPlayer', 'pid': pid});
    final response = await _client.receive(timeout: const Duration(seconds: 5));
    if (response['type'] != 'ready' || response['attached'] != true) {
      throw AppException.process('ISO Bridge 未确认播放器绑定');
    }
    _attached = true;
    await _client.close();
  }

  @override
  Future<void> cleanup() async {
    if (_cleaned) return;
    _cleaned = true;
    if (!_attached && _client.isConnected) {
      try {
        await _client.send(const {'type': 'shutdown'});
      } on IsoBridgeProtocolException {
        _helperProcess.kill();
      }
    }
    await _client.close();
    if (remoteMenu) {
      try {
        await _helperProcess.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        _helperProcess.kill();
        await _helperProcess.exitCode;
      }
    }
    if (await sessionDirectory.exists()) {
      await sessionDirectory.delete(recursive: true);
    }
  }
}

typedef IsoBridgeHelperPathResolver = Future<String> Function();
typedef IsoBridgeProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);
typedef IsoBridgeClientConnector =
    Future<IsoBridgeClient> Function({
      required String pipeName,
      required int helperPid,
    });

/// 启动固定版本 native helper，并通过内存 IPC 建立 WebDAV ISO 流式访问。
class IsoBridgeAccessProvider implements IsoAccessProvider {
  IsoBridgeAccessProvider({
    PlayerProcessController? processController,
    IsoBridgeHelperPathResolver? helperPathResolver,
    IsoBridgeProcessStarter? processStarter,
    IsoBridgeClientConnector? clientConnector,
    this.remoteMenu = false,
  }) : _processController = processController ?? PlayerProcessController(),
       _helperPathResolver =
           helperPathResolver ?? IsoBridgeAccessProvider._defaultHelperPath,
       _processStarter = processStarter ?? IsoBridgeAccessProvider._startHelper,
       _clientConnector = clientConnector ?? IsoBridgeClient.connect;

  final PlayerProcessController _processController;
  final IsoBridgeHelperPathResolver _helperPathResolver;
  final IsoBridgeProcessStarter _processStarter;
  final IsoBridgeClientConnector _clientConnector;
  final bool remoteMenu;
  Process? _activeProcess;
  IsoBridgeClient? _activeClient;
  bool _cancelRequested = false;

  @override
  Future<IsoAccessHandle> prepare({
    required WebDAVService webDavService,
    required WebDavFile file,
    required Directory sessionDirectory,
    required String structureCachePath,
    void Function(IsoAccessPhase phase)? onPhase,
    Future<void> Function(PlayerProcessIdentity identity)? onHelperStarted,
  }) async {
    if (!Platform.isWindows) {
      throw AppException.config('ISO Bridge 仅支持 Windows x64');
    }
    if (!file.isIso) throw AppException.config('仅支持 Blu-ray ISO 文件');
    if (_activeProcess != null) {
      throw AppException.process('ISO 远程播放测试模块正在执行其他任务');
    }
    _cancelRequested = false;
    await sessionDirectory.create(recursive: true);
    Process? process;
    IsoBridgeClient? client;
    try {
      onPhase?.call(IsoAccessPhase.startingBridge);
      final helperPath = await _helperPathResolver();
      final helperFile = File(helperPath);
      if (!await helperFile.exists()) {
        throw AppException.config('ISO Bridge helper 不存在');
      }
      final pipeSuffix = 'streampath_iso_${_randomHex(16)}';
      final pipeName = '${r'\\.\pipe\'}$pipeSuffix';
      process = await _processStarter(helperPath, [
        '--pipe=$pipeSuffix',
        '--parent-pid=${GetCurrentProcessId()}',
      ]);
      _activeProcess = process;
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      final identity = await _captureIdentity(process.pid);
      if (identity == null) {
        throw AppException.process('无法确认 ISO Bridge helper 身份');
      }
      await onHelperStarted?.call(identity);
      client = await _clientConnector(
        pipeName: pipeName,
        helperPid: process.pid,
      );
      _activeClient = client;
      final hello = await client.receive(timeout: const Duration(seconds: 10));
      if (hello['type'] != 'hello' ||
          hello['version'] != 1 ||
          hello['pid'] != process.pid) {
        throw const IsoBridgeProtocolException('ISO Bridge hello 响应无效');
      }
      final snapshot = webDavService.credentialSnapshot;
      onPhase?.call(IsoAccessPhase.probingStream);
      await client.send({
        'type': remoteMenu ? 'open_disc' : 'open',
        if (remoteMenu) 'mode': 'hdmv',
        if (remoteMenu) 'transport': 'winfsp',
        'version': 1,
        'url': webDavService.resolveUrl(file.href),
        'origin': snapshot.baseUrl,
        'username': snapshot.username,
        'password': snapshot.password,
        'sessionPath': sessionDirectory.path,
        'structureCachePath': structureCachePath,
      });
      Map<String, dynamic> response;
      while (true) {
        response = await client.receive();
        if (response['type'] != 'metrics') break;
        if (response['stage'] == 'parsingTitles') {
          onPhase?.call(IsoAccessPhase.parsingTitles);
        }
      }
      if (response['type'] == 'error') {
        throw _bridgeError(response);
      }
      final ready = IsoBridgeReady.fromMessage(
        response,
        remoteMenu: remoteMenu,
        mountedSessionPath: remoteMenu ? sessionDirectory.path : null,
      );
      if (_cancelRequested) {
        throw AppException.network('ISO 流式播放已取消');
      }
      final handle = LoopbackIsoAccessHandle(
        sessionDirectory: sessionDirectory,
        helperIdentity: identity,
        totalBytes: ready.totalBytes,
        titles: ready.titles,
        port: ready.port,
        token: ready.token,
        client: client,
        helperProcess: process,
        remoteMenu: remoteMenu,
        discPath: ready.discPath,
      );
      _activeProcess = null;
      _activeClient = null;
      return handle;
    } on IsoBridgeProtocolException catch (error) {
      throw AppException.process('ISO Bridge 通信失败', error);
    } on ProcessException catch (error) {
      throw AppException.process('无法启动 ISO Bridge helper', error);
    } finally {
      if (_activeProcess != null) {
        await client?.close();
        process?.kill();
        if (process != null) await process.exitCode;
        if (await sessionDirectory.exists()) {
          await sessionDirectory.delete(recursive: true);
        }
        _activeProcess = null;
        _activeClient = null;
      }
    }
  }

  @override
  void cancel() {
    _cancelRequested = true;
    unawaited(_activeClient?.close());
    _activeProcess?.kill();
  }

  Future<PlayerProcessIdentity?> _captureIdentity(int pid) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final identity = await _processController.capture(pid);
      if (identity != null) return identity;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  static Future<String> _defaultHelperPath() async => p.join(
    p.dirname(Platform.resolvedExecutable),
    'streampath_iso_bridge.exe',
  );

  static Future<Process> _startHelper(
    String executable,
    List<String> arguments,
  ) => Process.start(executable, arguments);

  static AppException _bridgeError(Map<String, dynamic> response) {
    final code = response['code'] is String ? response['code'] as String : '';
    return switch (code) {
      'range_unsupported' ||
      'length_unavailable' => AppException.network('当前 WebDAV 源不支持 ISO 流式随机读取'),
      'remote_changed' => AppException.network('远端 ISO 在播放期间发生变化'),
      'encrypted_disc' => AppException.config(
        '暂不支持 AACS 或 BD+ 加密的 Blu-ray ISO',
      ),
      'libbluray_unavailable' => AppException.config(
        'ISO Bridge 缺少固定版本 libbluray',
      ),
      'invalid_disc' => AppException.parse('没有解析到可播放的 Blu-ray Title/MPLS'),
      'network_error' => AppException.network('ISO Bridge 远端读取失败'),
      'bdj_unsupported' => AppException.config('当前阶段仅支持 HDMV 菜单，请返回标题模式'),
      'menu_unknown' => AppException.config('无法确认菜单类型，请返回标题模式'),
      'menu_unavailable' => AppException.config('当前组件不支持远程蓝光菜单'),
      'winfsp_unavailable' => AppException.config(
        '请先安装随附的 WinFsp 运行时，再使用远程蓝光菜单',
      ),
      _ => AppException.process('ISO Bridge 启动失败'),
    };
  }

  static String _randomHex(int byteCount) {
    final random = Random.secure();
    final output = StringBuffer();
    for (var index = 0; index < byteCount; index++) {
      output.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return output.toString();
  }
}
