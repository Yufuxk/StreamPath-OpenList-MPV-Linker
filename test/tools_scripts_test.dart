import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late Directory projectDir;
  late Directory toolsDir;
  late Map<String, String> isolatedEnvironment;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('streampath_tools_');
    projectDir = Directory(p.join(tempDir.path, 'project'))..createSync();
    toolsDir = Directory(p.join(projectDir.path, 'tools'))..createSync();
    File(
      p.join(projectDir.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: streampath_tool_fixture\n');

    final sourceTools = Directory(p.join(Directory.current.path, 'tools'));
    for (final name in const <String>[
      'build.ps1',
      'package.ps1',
      'cleanup.ps1',
      'run.ps1',
      'benchmark_iso_phase1.ps1',
      'benchmark_iso_phase4.ps1',
    ]) {
      File(
        p.join(sourceTools.path, name),
      ).copySync(p.join(toolsDir.path, name));
    }

    final fakeUser = Directory(p.join(tempDir.path, 'user'))..createSync();
    final fakeAppData = Directory(p.join(fakeUser.path, 'AppData', 'Roaming'))
      ..createSync(recursive: true);
    final fakeLocalAppData = Directory(
      p.join(fakeUser.path, 'AppData', 'Local'),
    )..createSync(recursive: true);
    final fakeTemp = Directory(p.join(tempDir.path, 'temp'))..createSync();
    isolatedEnvironment = <String, String>{
      ...Platform.environment,
      'USERPROFILE': fakeUser.path,
      'APPDATA': fakeAppData.path,
      'LOCALAPPDATA': fakeLocalAppData.path,
      'TEMP': fakeTemp.path,
      'TMP': fakeTemp.path,
    };
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File fixtureFile(String relativePath, [String contents = 'sentinel']) {
    final file = File(p.join(tempDir.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    return file;
  }

  Future<({int exitCode, String output})> runScript(
    String name, {
    List<String> arguments = const <String>[],
    List<String> inputLines = const <String>[],
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      'powershell.exe',
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        p.join(toolsDir.path, name),
        ...arguments,
      ],
      workingDirectory: tempDir.path,
      environment: environment ?? isolatedEnvironment,
    );
    final stdoutFuture = process.stdout
        .transform(systemEncoding.decoder)
        .join();
    final stderrFuture = process.stderr
        .transform(systemEncoding.decoder)
        .join();
    for (final line in inputLines) {
      process.stdin.writeln(line);
    }
    await process.stdin.close();
    final exitCode = await process.exitCode;
    final output = '${await stdoutFuture}${await stderrFuture}';
    return (exitCode: exitCode, output: output);
  }

  Future<void> createJunction(String link, String target) async {
    final result = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-Command',
      r'& { param($link, $target) New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null }',
      link,
      target,
    ], environment: isolatedEnvironment);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }

  test('build 以真实项目根为边界并拒绝项目内部打包目标', () async {
    final target = Directory(p.join(projectDir.path, 'inside-package'));

    final result = await runScript(
      'build.ps1',
      arguments: <String>['-ValidateTargetOnly', '-Target', target.path],
    );

    expect(result.exitCode, isNot(0), reason: result.output);
    expect(target.existsSync(), isFalse);
  });

  test('build 在项目标记缺失时失败关闭', () async {
    File(p.join(projectDir.path, 'pubspec.yaml')).deleteSync();
    final target = p.join(tempDir.path, 'outside-package');

    final result = await runScript(
      'build.ps1',
      arguments: <String>['-ValidateTargetOnly', '-Target', target],
    );

    expect(result.exitCode, isNot(0), reason: result.output);
    expect(Directory(target).existsSync(), isFalse);
  });

  test('package 的默认目标位于项目目录外且取消时不创建目录', () async {
    final expected = p.join(tempDir.path, 'StreamPath 20260809 V0.1 portable');
    final wrong = p.join(projectDir.path, 'StreamPath 20260809 V0.1 portable');

    final result = await runScript(
      'package.ps1',
      inputLines: const <String>['', 'n'],
    );

    expect(result.exitCode, 0, reason: result.output);
    expect(result.output, contains(expected));
    expect(Directory(expected).existsSync(), isFalse);
    expect(Directory(wrong).existsSync(), isFalse);
  });

  test('run 从真实项目根调用 Flutter', () async {
    final fakeBin = Directory(p.join(tempDir.path, 'fake-bin'))..createSync();
    final cwdFile = File(p.join(tempDir.path, 'flutter-cwd.txt'));
    File(p.join(fakeBin.path, 'flutter.cmd')).writeAsStringSync(
      '@echo off\r\ncd > "%FAKE_FLUTTER_CWD_FILE%"\r\nexit /b 0\r\n',
    );
    final pathKey = isolatedEnvironment.keys.firstWhere(
      (key) => key.toLowerCase() == 'path',
      orElse: () => 'Path',
    );
    final environment = <String, String>{
      ...isolatedEnvironment,
      pathKey:
          '${fakeBin.path}${Platform.isWindows ? ';' : ':'}'
          '${isolatedEnvironment[pathKey] ?? ''}',
      'FAKE_FLUTTER_CWD_FILE': cwdFile.path,
    };

    final result = await runScript(
      'run.ps1',
      inputLines: const <String>['1'],
      environment: environment,
    );

    expect(result.exitCode, 0, reason: result.output);
    expect(cwdFile.readAsStringSync().trim(), projectDir.path);
  });

  test('ISO Phase 1 Benchmark 排除预热并输出固定统计口径', () async {
    final archiveRoot = Directory(p.join(tempDir.path, 'iso_benchmarks'))
      ..createSync();
    for (var run = 1; run <= 6; run++) {
      final archive = Directory(
        p.join(archiveRoot.path, 'iso_${run.toString().padLeft(2, '0')}'),
      )..createSync();
      File(p.join(archive.path, 'iso-performance.json')).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'status': 'complete',
          'timings': {
            'openToProbeMs': run,
            'probeToTitlesMs': run,
            'selectionToLoopbackReadyMs': run,
            'selectionToStablePlaybackMs': run,
            'mpvLaunchToStablePlaybackMs': run,
          },
          'seekRecoveryMs': [run * 10],
          'titleSwitchGapMs': [run * 20],
        }),
      );
      File(p.join(archive.path, 'iso-bridge-metrics.json')).writeAsStringSync(
        jsonEncode({
          'version': 2,
          'network': {
            'requestCount': run,
            'redirectCount': 0,
            'redirectResolveCount': 0,
            'resolvedUrlReuseCount': run,
            'responseHeaderLatencyUsTotal': run,
            'responseBodyActiveUsTotal': run,
            'remoteBodyBytes': run,
            'probeBodyBytes': 1,
            'activeRequestPeak': 1,
          },
          'cache': {
            'foregroundFetchBytes': run,
            'prefetchFetchBytes': run,
            'consumerBytesDelivered': run,
            'cacheHitCount': run,
            'cacheMissCount': run,
            'prefetchHitCount': run,
            'prefetchUnusedBytes': run,
            'cancelledForegroundBytes': 0,
            'cancelledPrefetchBytes': 0,
            'evictionCount': run,
            'refetchCount': run,
          },
          'bluray': {
            'contextCreateCount': run,
            'contextCreateUsTotal': run,
            'titleEnumerationUs': run,
            'mediaGetCount': run,
          },
          'bridge': {'final': true},
        }),
      );
    }
    final output = p.join(tempDir.path, 'benchmark-report.json');
    List<String> benchmarkArguments(String mode) => <String>[
      '-ArchiveRoot',
      archiveRoot.path,
      '-Mode',
      mode,
      '-MachineProfile',
      'machine-a',
      '-SampleId',
      'sample-a',
      '-MpvProfile',
      'mpv-a',
      '-NetworkProfile',
      'lan-webdav',
      '-NetworkShaping',
      'none',
      '-OutputPath',
      output,
    ];

    final result = await runScript(
      'benchmark_iso_phase1.ps1',
      arguments: <String>[
        '-ArchiveRoot',
        archiveRoot.path,
        '-Mode',
        'Cold',
        '-MachineProfile',
        'machine-a',
        '-SampleId',
        'sample-a',
        '-MpvProfile',
        'mpv-a',
        '-NetworkProfile',
        'lan-webdav',
        '-NetworkShaping',
        'none',
        '-OutputPath',
        output,
      ],
    );

    expect(result.exitCode, 0, reason: result.output);
    final reportText = File(output).readAsStringSync();
    final report = jsonDecode(reportText) as Map<String, dynamic>;
    final statistics = report['statistics'] as Map<String, dynamic>;
    final openToProbe = statistics['openToProbeMs'] as Map<String, dynamic>;
    expect(report['runCount'], 5);
    expect(report['warmupExcluded'], 1);
    expect(report['measuredRunCount'], 4);
    expect(openToProbe['median'], 4.5);
    expect(openToProbe['p95'], 6);
    expect(
      statistics.containsKey('blurayPersistentContextReuseCount'),
      isFalse,
    );
    expect(reportText, isNot(contains(archiveRoot.path)));

    for (var run = 1; run <= 6; run++) {
      final metricsFile = File(
        p.join(
          archiveRoot.path,
          'iso_${run.toString().padLeft(2, '0')}',
          'iso-bridge-metrics.json',
        ),
      );
      final metrics =
          jsonDecode(metricsFile.readAsStringSync()) as Map<String, dynamic>;
      (metrics['bluray']
              as Map<String, dynamic>)['persistentContextReuseCount'] =
          run;
      metrics['metadataNetwork'] = {
        'requestCount': run,
        'responseHeaderLatencyUsTotal': run,
        'remoteBodyBytes': run,
      };
      metrics['playbackNetwork'] = {
        'requestCount': run,
        'responseHeaderLatencyUsTotal': run,
        'remoteBodyBytes': run,
      };
      metrics['metadataCache'] = {
        'requestCount': run,
        'foregroundFetchBytes': run,
        'consumerBytesDelivered': run,
        'cacheHitCount': run,
        'cacheMissCount': run,
        'evictionCount': run,
        'refetchCount': run,
        'capacityBytes': 64 * 1024 * 1024,
        'blockBytes': 256 * 1024,
        'retainedBytes': 16 * 1024 * 1024,
      };
      metrics['playbackCache'] = {
        'requestCount': run,
        'foregroundFetchBytes': run,
        'consumerBytesDelivered': run,
        'cacheHitCount': run,
        'cacheMissCount': run,
        'evictionCount': run,
        'refetchCount': run,
        'capacityBytes': 64 * 1024 * 1024,
        'blockBytes': 256 * 1024,
      };
      metricsFile.writeAsStringSync(jsonEncode(metrics));
    }
    final currentMetrics = await runScript(
      'benchmark_iso_phase1.ps1',
      arguments: <String>[
        '-ArchiveRoot',
        archiveRoot.path,
        '-Mode',
        'Cold',
        '-MachineProfile',
        'machine-a',
        '-SampleId',
        'sample-a',
        '-MpvProfile',
        'mpv-a',
        '-NetworkProfile',
        'lan-webdav',
        '-NetworkShaping',
        'none',
        '-OutputPath',
        output,
      ],
    );
    expect(currentMetrics.exitCode, 0, reason: currentMetrics.output);
    final currentReport =
        jsonDecode(File(output).readAsStringSync()) as Map<String, dynamic>;
    final currentStatistics =
        currentReport['statistics'] as Map<String, dynamic>;
    final persistentReuse =
        currentStatistics['blurayPersistentContextReuseCount']
            as Map<String, dynamic>;
    expect(persistentReuse['median'], 4.5);
    expect(persistentReuse['p95'], 6);
    final metadataRequests =
        currentStatistics['metadataCacheRequestCount'] as Map<String, dynamic>;
    expect(metadataRequests['median'], 4.5);
    expect(metadataRequests['p95'], 6);
    final playbackRequests =
        currentStatistics['playbackCacheRequestCount'] as Map<String, dynamic>;
    expect(playbackRequests['median'], 4.5);
    expect(playbackRequests['p95'], 6);

    for (var run = 1; run <= 6; run++) {
      final metricsFile = File(
        p.join(
          archiveRoot.path,
          'iso_${run.toString().padLeft(2, '0')}',
          'iso-bridge-metrics.json',
        ),
      );
      final metrics =
          jsonDecode(metricsFile.readAsStringSync()) as Map<String, dynamic>;
      (metrics['bluray'] as Map<String, dynamic>)['structureCacheHit'] =
          run >= 3;
      metricsFile.writeAsStringSync(jsonEncode(metrics));
    }
    final warmMetrics = await runScript(
      'benchmark_iso_phase1.ps1',
      arguments: <String>[
        '-ArchiveRoot',
        archiveRoot.path,
        '-Mode',
        'Warm',
        '-MachineProfile',
        'machine-a',
        '-SampleId',
        'sample-a',
        '-MpvProfile',
        'mpv-a',
        '-NetworkProfile',
        'lan-webdav',
        '-NetworkShaping',
        'none',
        '-OutputPath',
        output,
      ],
    );
    expect(warmMetrics.exitCode, 0, reason: warmMetrics.output);
    final warmReport =
        jsonDecode(File(output).readAsStringSync()) as Map<String, dynamic>;
    final structureCache = warmReport['structureCache'] as Map<String, dynamic>;
    expect(structureCache['hits'], 4);
    expect(structureCache['misses'], 0);
    expect(structureCache['hitRate'], 1);
    final structureLatestMetrics = File(
      p.join(archiveRoot.path, 'iso_06', 'iso-bridge-metrics.json'),
    );
    final structureLatest =
        jsonDecode(structureLatestMetrics.readAsStringSync())
            as Map<String, dynamic>;
    (structureLatest['bluray'] as Map<String, dynamic>).remove(
      'structureCacheHit',
    );
    structureLatestMetrics.writeAsStringSync(jsonEncode(structureLatest));
    final mixedStructureCache = await runScript(
      'benchmark_iso_phase1.ps1',
      arguments: benchmarkArguments('Warm'),
    );
    expect(mixedStructureCache.exitCode, isNot(0));
    expect(
      mixedStructureCache.output,
      contains(
        'structureCacheHit must be present in every selected run or absent',
      ),
    );
    (structureLatest['bluray'] as Map<String, dynamic>)['structureCacheHit'] =
        false;
    structureLatestMetrics.writeAsStringSync(jsonEncode(structureLatest));
    final warmMiss = await runScript(
      'benchmark_iso_phase1.ps1',
      arguments: benchmarkArguments('Warm'),
    );
    expect(warmMiss.exitCode, isNot(0));
    expect(
      warmMiss.output,
      contains('Every measured Warm run must report structureCacheHit=true'),
    );
    for (var run = 1; run <= 6; run++) {
      final metricsFile = File(
        p.join(
          archiveRoot.path,
          'iso_${run.toString().padLeft(2, '0')}',
          'iso-bridge-metrics.json',
        ),
      );
      final metrics =
          jsonDecode(metricsFile.readAsStringSync()) as Map<String, dynamic>;
      (metrics['bluray'] as Map<String, dynamic>).remove('structureCacheHit');
      metricsFile.writeAsStringSync(jsonEncode(metrics));
    }

    final latestMetrics = File(
      p.join(archiveRoot.path, 'iso_06', 'iso-bridge-metrics.json'),
    );
    final mixedMetrics =
        jsonDecode(latestMetrics.readAsStringSync()) as Map<String, dynamic>;
    (mixedMetrics['bluray'] as Map<String, dynamic>).remove(
      'persistentContextReuseCount',
    );
    latestMetrics.writeAsStringSync(jsonEncode(mixedMetrics));
    final mixed = await runScript(
      'benchmark_iso_phase1.ps1',
      arguments: <String>[
        '-ArchiveRoot',
        archiveRoot.path,
        '-Mode',
        'Cold',
        '-MachineProfile',
        'machine-a',
        '-SampleId',
        'sample-a',
        '-MpvProfile',
        'mpv-a',
        '-NetworkProfile',
        'lan-webdav',
        '-NetworkShaping',
        'none',
        '-OutputPath',
        output,
      ],
    );
    expect(mixed.exitCode, isNot(0));
    expect(
      mixed.output,
      contains('must be present in every selected run or absent'),
    );

    (mixedMetrics['bluray']
            as Map<String, dynamic>)['persistentContextReuseCount'] =
        6;
    latestMetrics.writeAsStringSync(jsonEncode(mixedMetrics));
    final incompleteMetrics =
        jsonDecode(latestMetrics.readAsStringSync()) as Map<String, dynamic>;
    (incompleteMetrics['bridge'] as Map<String, dynamic>)['final'] = false;
    latestMetrics.writeAsStringSync(jsonEncode(incompleteMetrics));
    final incomplete = await runScript(
      'benchmark_iso_phase1.ps1',
      arguments: <String>[
        '-ArchiveRoot',
        archiveRoot.path,
        '-Mode',
        'Cold',
        '-MachineProfile',
        'machine-a',
        '-SampleId',
        'sample-a',
        '-MpvProfile',
        'mpv-a',
        '-NetworkProfile',
        'lan-webdav',
        '-NetworkShaping',
        'none',
        '-OutputPath',
        output,
      ],
    );
    expect(incomplete.exitCode, isNot(0));
    expect(incomplete.output, contains('Final native metrics are required'));
  });

  test('ISO Phase 4 配对汇总执行 Seek 双门禁并拒绝错位或混合 schema', () async {
    final baselineRoot = Directory(p.join(tempDir.path, 'phase4-baseline'))
      ..createSync();
    final candidateRoot = Directory(p.join(tempDir.path, 'phase4-candidate'))
      ..createSync();

    void writeRun(Directory root, int run, {required bool candidate}) {
      final archive = Directory(
        p.join(root.path, 'iso_${run.toString().padLeft(2, '0')}'),
      )..createSync();
      final recovery = candidate ? 8000 : 9000;
      File(p.join(archive.path, 'iso-performance.json')).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'status': 'complete',
          'seekRecoveryMs': [recovery],
          'seekSamples': [
            {
              'playlist': '00001',
              'startPositionMs': 700000,
              'endPositionMs': candidate ? 700100 : 700200,
              'recoveryMs': recovery,
            },
          ],
          'titleSwitchGapMs': const <int>[],
          'pausedForCacheCount': candidate ? 0 : 1,
          'pausedForCacheDurationMs': candidate ? 0 : 100,
          'cachePlan': {
            'bridgeBytes': 32 * 1024 * 1024,
            'titles': [
              {
                'playlist': '00001',
                'bitrateMbps': 100.0,
                'mpvMaxBytes': 128 * 1024 * 1024,
                'totalBudgetBytes': 160 * 1024 * 1024,
              },
            ],
          },
        }),
      );
      File(p.join(archive.path, 'iso-bridge-metrics.json')).writeAsStringSync(
        jsonEncode({
          'version': 2,
          'network': {
            'requestCount': 100,
            'remoteBodyBytes': 100000000,
            'activeRequestPeak': candidate ? 3 : 2,
            'remoteTransferWallClockUs': candidate ? 800000 : 1000000,
            'concurrentTransferWallClockUs': candidate ? 300000 : 0,
            'requestContextCreatedCount': 100,
            'requestContextClosedCount': 100,
            'requestContextLive': 0,
          },
          'cache': {
            'prefetchFetchBytes': 80000000,
            'prefetchUnusedBytes': 1000,
            'cancelledPrefetchBytes': 1000,
            'prefetchActivePeak': candidate ? 2 : 1,
            'prefetchOverlapCount': candidate ? 3 : 0,
            'prefetchPendingGapUsTotal': candidate ? 40 : 100,
            'prefetchPendingGapUsMax': candidate ? 20 : 50,
            'prefetchInFlightBytesPeak': candidate
                ? 32 * 1024 * 1024
                : 16 * 1024 * 1024,
            'prefetchHitBytes': 60000000,
            'prefetchConcurrentWallClockUs': candidate ? 250000 : 0,
          },
          'bluray': {'persistentContextReuseCount': 10},
          'bridge': {'final': true},
          'cacheCapacityBytes': 64 * 1024 * 1024,
        }),
      );
    }

    for (var run = 1; run <= 6; run++) {
      writeRun(baselineRoot, run, candidate: false);
      writeRun(candidateRoot, run, candidate: true);
    }
    final output = p.join(tempDir.path, 'phase4-report.json');
    final arguments = <String>[
      '-BaselineArchiveRoot',
      baselineRoot.path,
      '-CandidateArchiveRoot',
      candidateRoot.path,
      '-NetworkKind',
      'Controlled',
      '-OrderPattern',
      'AlternatingBaselineFirst',
      '-MachineProfile',
      'machine-a',
      '-SampleId',
      'sample-a',
      '-MpvProfile',
      'mpv-a',
      '-NetworkProfile',
      'high-ttfb',
      '-NetworkShaping',
      '100ms',
      '-OutputPath',
      output,
    ];

    final passed = await runScript(
      'benchmark_iso_phase4.ps1',
      arguments: arguments,
    );
    expect(passed.exitCode, 0, reason: passed.output);
    final reportText = File(output).readAsStringSync();
    final report = jsonDecode(reportText) as Map<String, dynamic>;
    expect(report['adoptable'], isTrue);
    expect(
      (report['gates']
          as Map<String, dynamic>)['baselineEntryConditionSatisfied'],
      isTrue,
    );
    expect(report['measuredRunCount'], 5);
    expect(reportText, isNot(contains(baselineRoot.path)));
    expect(reportText, isNot(contains(candidateRoot.path)));

    final latestSummary = File(
      p.join(candidateRoot.path, 'iso_06', 'iso-performance.json'),
    );
    final mismatched =
        jsonDecode(latestSummary.readAsStringSync()) as Map<String, dynamic>;
    ((mismatched['seekSamples'] as List).first
            as Map<String, dynamic>)['startPositionMs'] =
        700001;
    latestSummary.writeAsStringSync(jsonEncode(mismatched));
    final mismatch = await runScript(
      'benchmark_iso_phase4.ps1',
      arguments: arguments,
    );
    expect(mismatch.exitCode, isNot(0));
    expect(mismatch.output, contains('targets a different position'));

    ((mismatched['seekSamples'] as List).first
            as Map<String, dynamic>)['startPositionMs'] =
        700000;
    latestSummary.writeAsStringSync(jsonEncode(mismatched));
    final latestMetrics = File(
      p.join(candidateRoot.path, 'iso_06', 'iso-bridge-metrics.json'),
    );
    final mixed =
        jsonDecode(latestMetrics.readAsStringSync()) as Map<String, dynamic>;
    (mixed['cache'] as Map<String, dynamic>).remove('prefetchHitBytes');
    latestMetrics.writeAsStringSync(jsonEncode(mixed));
    final mixedSchema = await runScript(
      'benchmark_iso_phase4.ps1',
      arguments: arguments,
    );
    expect(mixedSchema.exitCode, isNot(0));
    expect(mixedSchema.output, contains('mixes schemas'));

    latestMetrics.writeAsStringSync(
      jsonEncode({
        ...mixed,
        'cache': {
          ...(mixed['cache'] as Map<String, dynamic>),
          'prefetchHitBytes': 60000000,
        },
      }),
    );
    for (final root in [baselineRoot, candidateRoot]) {
      for (var run = 1; run <= 6; run++) {
        final summaryFile = File(
          p.join(
            root.path,
            'iso_${run.toString().padLeft(2, '0')}',
            'iso-performance.json',
          ),
        );
        final summary =
            jsonDecode(summaryFile.readAsStringSync()) as Map<String, dynamic>;
        ((((summary['cachePlan'] as Map<String, dynamic>)['titles'] as List)
                    .first)
                as Map<String, dynamic>)['bitrateMbps'] =
            1000.0;
        summaryFile.writeAsStringSync(jsonEncode(summary));
      }
    }
    final noEntrySignal = await runScript(
      'benchmark_iso_phase4.ps1',
      arguments: arguments,
    );
    expect(noEntrySignal.exitCode, isNot(0));
    expect(noEntrySignal.output, contains('failed one or more adoption gates'));
  });

  test('cleanup 默认只清理项目数据并保留学习数据', () async {
    final expectedRuntime = fixtureFile(
      p.join('project', 'stream_path_data', 'cache', 'mpv.log'),
    );
    final learning = fixtureFile(
      p.join(
        'project',
        'stream_path_data',
        'cache',
        'cache_intelligence_learning.json',
      ),
    );
    final wrongRuntime = fixtureFile(
      p.join('project', 'tools', 'stream_path_data', 'cache', 'mpv.log'),
    );

    final result = await runScript('cleanup.ps1');

    expect(result.exitCode, 0, reason: result.output);
    expect(expectedRuntime.existsSync(), isFalse);
    expect(learning.existsSync(), isTrue);
    expect(wrongRuntime.existsSync(), isTrue);
  });

  test('cleanup 指定测试目录时不扫描隔离环境中的旧用户路径', () async {
    final dataDir = Directory(p.join(tempDir.path, 'explicit-data'));
    final runtime = fixtureFile(p.join('explicit-data', 'cache', 'mpv.log'));
    final learning = fixtureFile(
      p.join('explicit-data', 'cache', 'cache_intelligence_learning.json'),
    );
    final legacy = File(
      p.join(
        isolatedEnvironment['APPDATA']!,
        'com.streampath',
        'streampath',
        'streampath.db',
      ),
    );
    legacy.parent.createSync(recursive: true);
    legacy.writeAsStringSync('legacy-sentinel');

    final result = await runScript(
      'cleanup.ps1',
      arguments: <String>['-DataDir', dataDir.path],
    );

    expect(result.exitCode, 0, reason: result.output);
    expect(runtime.existsSync(), isFalse);
    expect(learning.existsSync(), isTrue);
    expect(legacy.existsSync(), isTrue);
  });

  test('cleanup 拒绝数据目录祖先中的重解析点', () async {
    final realParent = Directory(p.join(tempDir.path, 'real-parent'))
      ..createSync();
    final dataDir = Directory(p.join(realParent.path, 'data'));
    final runtime = fixtureFile(
      p.join('real-parent', 'data', 'cache', 'mpv.log'),
    );
    final junction = p.join(tempDir.path, 'junction-parent');
    await createJunction(junction, realParent.path);

    final result = await runScript(
      'cleanup.ps1',
      arguments: <String>[
        '-DataDir',
        p.join(junction, p.basename(dataDir.path)),
      ],
    );

    expect(result.exitCode, isNot(0), reason: result.output);
    expect(result.output, contains('重解析点'));
    expect(runtime.existsSync(), isTrue);
  });

  test('cleanup 拒绝递归删除包含重解析点的候选目录', () async {
    final dataDir = Directory(p.join(tempDir.path, 'nested-data'))
      ..createSync();
    final candidate = Directory(p.join(dataDir.path, 'directory_cache'))
      ..createSync();
    final external = Directory(p.join(tempDir.path, 'external-cache'))
      ..createSync();
    final sentinel = File(p.join(external.path, 'keep.txt'))
      ..writeAsStringSync('keep');
    await createJunction(
      p.join(candidate.path, 'external-link'),
      external.path,
    );

    final result = await runScript(
      'cleanup.ps1',
      arguments: <String>['-DataDir', dataDir.path],
    );

    expect(result.exitCode, isNot(0), reason: result.output);
    expect(result.output, contains('重解析点'));
    expect(sentinel.existsSync(), isTrue);
  });
}
