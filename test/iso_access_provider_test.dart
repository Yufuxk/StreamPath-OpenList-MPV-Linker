import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/iso_access_provider.dart';
import 'package:streampath/domain/services/iso_bridge_client.dart';

void main() {
  test('ready 响应解析 Title、章节与流长度', () {
    final ready = IsoBridgeReady.fromMessage({
      'type': 'ready',
      'version': 1,
      'port': 49152,
      'token': '0123456789abcdef0123456789abcdef',
      'totalBytes': 100000,
      'titles': [
        {
          'titleIndex': 0,
          'mplsId': '00001',
          'durationMs': 120000,
          'size': 400000,
          'chapters': [
            {'startMs': 0, 'durationMs': 60000, 'name': 'Chapter 1'},
            {'startMs': 60000, 'durationMs': 60000},
          ],
        },
      ],
    });

    expect(ready.port, 49152);
    expect(ready.totalBytes, 100000);
    expect(ready.titles.single.mplsId, '00001');
    expect(ready.titles.single.chapters, hasLength(2));
    expect(ready.titles.single.chapters.last.start, const Duration(minutes: 1));
  });

  test('ready 拒绝重复 MPLS 与畸形 token', () {
    Map<String, Object> message(String token) => {
      'type': 'ready',
      'version': 1,
      'port': 49152,
      'token': token,
      'totalBytes': 100000,
      'titles': <Object>[
        {
          'titleIndex': 0,
          'mplsId': '00001',
          'durationMs': 120000,
          'size': 400000,
          'chapters': <Object>[],
        },
      ],
    };

    expect(
      () => IsoBridgeReady.fromMessage(message('secret')),
      throwsA(isA<IsoBridgeProtocolException>()),
    );

    final duplicate = message('0123456789abcdef0123456789abcdef');
    (duplicate['titles']! as List<Object>).add({
      'titleIndex': 1,
      'mplsId': '00001',
      'durationMs': 1000,
      'size': 1000,
      'chapters': <Object>[],
    });
    expect(
      () => IsoBridgeReady.fromMessage(duplicate),
      throwsA(isA<IsoBridgeProtocolException>()),
    );
  });

  test('ready 拒绝非法章节边界', () {
    expect(
      () => IsoBridgeReady.fromMessage({
        'type': 'ready',
        'version': 1,
        'port': 49152,
        'token': '0123456789abcdef0123456789abcdef',
        'totalBytes': 100000,
        'titles': [
          {
            'titleIndex': 0,
            'mplsId': '00001',
            'durationMs': 120000,
            'size': 400000,
            'chapters': [
              {'startMs': -1, 'durationMs': 1000},
            ],
          },
        ],
      }),
      throwsA(isA<IsoBridgeProtocolException>()),
    );
  });

  test('metrics 同时兼容 v1 与 v2，缺失新字段保持未知', () {
    final legacy = IsoBridgeMetricsSnapshot.tryParse({
      'version': 1,
      'remoteTransferBytes': 100,
      'remoteTransferActiveMicroseconds': 25,
      'futureField': 'ignored',
    });
    final current = IsoBridgeMetricsSnapshot.tryParse({
      'version': 2,
      'network': {
        'remoteBodyBytes': 200,
        'remoteTransferWallClockUs': 35,
        'concurrentTransferWallClockUs': 5,
        'responseBodyActiveUsTotal': 40,
        'requestContextCreatedCount': 12,
        'requestContextClosedCount': 12,
        'requestContextLive': 0,
        'requestContextPeak': 2,
        'unknownCounter': 9,
      },
      'cache': {
        'prefetchActivePeak': 2,
        'prefetchOverlapCount': 3,
        'prefetchPendingGapUsTotal': 4,
        'prefetchPendingGapUsMax': 2,
        'prefetchInFlightBytesPeak': 33554432,
        'prefetchHitBytes': 16777216,
        'prefetchConcurrentWallClockUs': 6,
      },
      'metadataNetwork': {
        'requestCount': 7,
        'redirectCount': 1,
        'responseHeaderLatencyUsTotal': 800,
        'responseBodyActiveUsTotal': 900,
        'remoteBodyBytes': 1000,
        'remoteTransferWallClockUs': 1100,
        'concurrentTransferWallClockUs': 0,
        'requestContextCreatedCount': 7,
        'requestContextClosedCount': 7,
      },
      'playbackNetwork': {'requestCount': 8, 'remoteBodyBytes': 1200},
      'metadataCache': {
        'requestCount': 6,
        'foregroundFetchBytes': 1300,
        'consumerBytesDelivered': 1400,
        'cacheHitCount': 15,
        'cacheMissCount': 16,
        'evictionCount': 17,
        'refetchCount': 18,
        'residentBytes': 19,
        'capacityBytes': 67108864,
        'configuredPrefetchBlocks': 12,
        'blockBytes': 262144,
        'retainedBytes': 16777216,
      },
      'playbackCache': {
        'requestCount': 20,
        'foregroundFetchBytes': 2100,
        'blockBytes': 262144,
      },
      'bluray': {
        'mediaFailureCount': 2,
        'lastMediaFailureSequence': 17,
        'lastMediaFailureGeneration': 9,
        'lastMediaFailureStatusCategory': 'http_5xx',
        'terminalRejectedMediaGetCount': 1,
        'structureCacheHit': true,
      },
      'bridge': {
        'firstMediaResponseReadyUs': 300,
        'final': true,
        'timeSeekRedirectEnabled': false,
        'demandBlockBytes': 262144,
      },
      'lastErrorCode': 'network_error',
      'remoteTransferActiveMicroseconds': 50,
      'errors': [
        {'error-type': 'bad_alloc'},
      ],
    });

    expect(legacy!.remoteBodyBytes, 100);
    expect(legacy.responseBodyActiveMicroseconds, isNull);
    expect(legacy.firstMediaResponseReadyMicroseconds, isNull);
    expect(current!.remoteBodyBytes, 200);
    expect(current.remoteTransferActiveMicroseconds, 50);
    expect(current.remoteTransferWallClockMicroseconds, 35);
    expect(current.concurrentTransferWallClockMicroseconds, 5);
    expect(current.responseBodyActiveMicroseconds, 40);
    expect(current.firstMediaResponseReadyMicroseconds, 300);
    expect(current.finalSnapshot, isTrue);
    expect(current.lastErrorCode, 'network_error');
    expect(current.mediaFailureCount, 2);
    expect(current.lastMediaFailureSequence, 17);
    expect(current.lastMediaFailureGeneration, 9);
    expect(current.lastMediaFailureStatusCategory, 'http_5xx');
    expect(current.terminalRejectedMediaGetCount, 1);
    expect(current.structureCacheHit, isTrue);
    expect(current.requestContextCreatedCount, 12);
    expect(current.requestContextClosedCount, 12);
    expect(current.requestContextLive, 0);
    expect(current.requestContextPeak, 2);
    expect(current.timeSeekRedirectEnabled, isFalse);
    expect(current.demandBlockBytes, 262144);
    expect(current.prefetchActivePeak, 2);
    expect(current.prefetchOverlapCount, 3);
    expect(current.prefetchPendingGapMicrosecondsTotal, 4);
    expect(current.prefetchPendingGapMicrosecondsMax, 2);
    expect(current.prefetchInFlightBytesPeak, 33554432);
    expect(current.prefetchHitBytes, 16777216);
    expect(current.prefetchConcurrentWallClockMicroseconds, 6);
    expect(current.metadataNetwork!.requestCount, 7);
    expect(current.metadataNetwork!.responseHeaderLatencyMicroseconds, 800);
    expect(current.metadataNetwork!.remoteBodyBytes, 1000);
    expect(current.playbackNetwork!.requestCount, 8);
    expect(current.playbackNetwork!.remoteBodyBytes, 1200);
    expect(current.metadataCache!.requestCount, 6);
    expect(current.metadataCache!.foregroundFetchBytes, 1300);
    expect(current.metadataCache!.cacheHitCount, 15);
    expect(current.metadataCache!.refetchCount, 18);
    expect(current.metadataCache!.capacityBytes, 67108864);
    expect(current.metadataCache!.retainedBytes, 16777216);
    expect(current.playbackCache!.requestCount, 20);
    expect(current.playbackCache!.blockBytes, 262144);
    expect(current.errorTypes, ['bad_alloc']);
    final olderV2 = IsoBridgeMetricsSnapshot.tryParse({'version': 2});
    expect(olderV2!.metadataNetwork, isNull);
    expect(olderV2.metadataCache, isNull);
    expect(olderV2.structureCacheHit, isNull);
    expect(IsoBridgeMetricsSnapshot.tryParse({'version': 3}), isNull);
  });
}
