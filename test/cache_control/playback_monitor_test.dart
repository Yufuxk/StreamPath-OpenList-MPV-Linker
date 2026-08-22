import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/monitor/playback_monitor.dart';
import 'package:streampath/features/cache_control/providers/system_memory_provider.dart';

/// PlaybackMonitor 单元测试（第二阶段：内存压力/网络异常/卡顿记录）。
///
/// 直接驱动 [PlaybackMonitor.sampleOnce]（不依赖真实 Timer），
/// 状态文件为临时文件，内存经 fake provider 注入。
void main() {
  late Directory dir;
  late File statusFile;

  /// 写一个 n 行状态文件（默认 7 行）。
  void writeStatus({
    double? duration = 7200,
    int? buffering = 0,
    double? speedKbps = 5000,
    int lines = 7,
  }) {
    final rows = <String>[
      '0',
      'http://h/dav/01.mkv',
      '0',
      '10.5',
      duration.toString(),
      buffering.toString(),
      (speedKbps! * 1024).round().toString(),
    ];
    statusFile.writeAsStringSync('${rows.take(lines).join('\n')}\n');
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('monitor_');
    statusFile = File('${dir.path}${Platform.pathSeparator}status.txt');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  PlaybackMonitor makeMonitor({
    SystemMemoryProvider? memory,
    double? bitrateMbps,
    int initialMax = 1024 * 1024 * 1024, // 1GiB
    int initialSecs = 120,
    int? memoryBudgetBytes,
    int? minCacheSecs,
    int? maxCacheSecs,
    int? fileSizeBytes,
    int? bufferingWarningStreak,
    Duration warningCooldown = const Duration(seconds: 60),
    void Function(CacheAdjustment)? onAdjustment,
    void Function(String)? onWarning,
    List<String>? logs,
  }) {
    return PlaybackMonitor(
      memoryProvider: memory ?? const _FakeMemory(8 * 1024 * 1024 * 1024),
      interval: const Duration(seconds: 5),
      warningCooldown: warningCooldown,
      bufferingWarningStreak: bufferingWarningStreak ?? 6,
      logger: logs?.add,
    )..start(
      statusFilePath: statusFile.path,
      initialDemuxerMaxBytes: initialMax,
      initialCacheSecs: initialSecs,
      fileSizeBytes: fileSizeBytes,
      bitrateMbps: bitrateMbps,
      memoryBudgetBytes: memoryBudgetBytes,
      minCacheSecs: minCacheSecs,
      maxCacheSecs: maxCacheSecs,
      onAdjustment: onAdjustment,
      onWarning: onWarning,
    );
  }

  /// 写入十三字段状态文件，并允许覆盖播放与缓存状态。
  void writeStatusFull({
    double timePos = 10.5,
    String paused = '0',
    double? duration = 7200,
    int? buffering = 0,
    double? speedKbps = 5000,
    String cacheIdle = '0', // 0=非空闲（真卡顿场景），1=缓存满（正常）
    String pausedForCache = '0',
    String bofCached = '0',
    String eofCached = '0',
  }) {
    statusFile.writeAsStringSync(
      '0\nhttp://h/dav/01.mkv\n$paused\n$timePos\n$duration\n'
      '$buffering\n${(speedKbps! * 1024).round()}\n$cacheIdle\n'
      'diag\n$pausedForCache\n$bofCached\n$eofCached\n1920x1080\n',
    );
  }

  group('内存压力保护（9.1）', () {
    test('可用内存持续低于阈值 → 缓存上限减半', () async {
      final adjustments = <CacheAdjustment>[];
      // 可用内存 800MB < 1GiB × 2.0 = 2GiB → 压力。
      final monitor = makeMonitor(
        memory: const _FakeMemory(800 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      await monitor.sampleOnce(); // 第 1 次：计数
      await monitor.sampleOnce(); // 第 2 次：触发降级
      expect(adjustments, isNotEmpty);
      expect(adjustments.first.demuxerMaxBytes, 512 * 1024 * 1024);
      expect(adjustments.first.cacheSecs, isNull);
      expect(adjustments.first.reason, contains('Memory pressure'));
      expect(monitor.currentDemuxerMaxBytes, 512 * 1024 * 1024);
      monitor.stop();
    });

    test('连续压力持续减半，不低于下限 64MiB', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        memory: const _FakeMemory(100 * 1024 * 1024), // 持续紧张
        onAdjustment: adjustments.add,
      );
      // 1GiB → 512MiB → 256MiB → 128MiB → 64MiB（下限，不再降）。
      for (var i = 0; i < 12; i++) {
        await monitor.sampleOnce();
      }
      expect(monitor.currentDemuxerMaxBytes, 64 * 1024 * 1024);
      final count = adjustments.length;
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(adjustments.length, count, reason: '到下限后不再降级');
      monitor.stop();
    });

    test('内存充足时不调整', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024), // 16GB
        onAdjustment: adjustments.add,
      );
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(adjustments, isEmpty);
      monitor.stop();
    });

    test('多会话共享预算：会话减少后立即恢复仅由共享造成的限额', () {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        initialMax: 1024 * 1024 * 1024,
        memoryBudgetBytes: 1024 * 1024 * 1024,
        onAdjustment: adjustments.add,
      );
      monitor.updateActiveSessionCount(2);
      expect(monitor.currentDemuxerMaxBytes, 512 * 1024 * 1024);
      monitor.updateActiveSessionCount(1);
      expect(monitor.currentDemuxerMaxBytes, 1024 * 1024 * 1024);
      expect(adjustments, hasLength(2));
      monitor.stop();
    });
  });

  group('网络异常保护（9.2）', () {
    test('mpv 正常态 buffering=100 仍参与带宽采样，不误判卡顿', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        onAdjustment: adjustments.add,
      );
      writeStatusFull(
        buffering: 100,
        speedKbps: 20000,
        cacheIdle: '0',
        pausedForCache: '0',
      );
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(monitor.stallCount, 0);
      expect(
        adjustments.any((a) => a.reason.contains('Layer3 network factor')),
        isTrue,
        reason: '正常态 100 不能阻断 Layer3 带宽采样',
      );
      monitor.stop();
    });

    test('paused-for-cache=true 即使 buffering=0 也识别为卡顿', () async {
      final monitor = makeMonitor(bitrateMbps: 40);
      writeStatusFull(
        buffering: 0,
        speedKbps: 0,
        cacheIdle: '0',
        pausedForCache: '1',
      );
      await monitor.sampleOnce();
      expect(monitor.stallCount, 1);
      monitor.stop();
    });

    test('下载速度持续低于码率需求 → 增档（Layer3 与 Slow network 均可能触发）', () async {
      final adjustments = <CacheAdjustment>[];
      // 码率 40Mbps → 需求 5MB/s；速度 1000KB/s ≈ 1MB/s < 5MB/s×1.2。
      final monitor = makeMonitor(
        bitrateMbps: 40,
        onAdjustment: adjustments.add,
      );
      writeStatus(speedKbps: 1000);
      await monitor.sampleOnce(); // 第 1 次：计数 + 带宽样本
      await monitor.sampleOnce(); // 第 2 次：触发调整
      expect(adjustments, isNotEmpty);
      // Layer 3（带宽 8Mbps/码率 40Mbps = 0.2 → +50% → 180s）或
      // Slow network（+60s）至少一种生效，且 cacheSecs 只增不减。
      expect(
        adjustments.any(
          (a) =>
              a.reason.contains('Layer3 network factor') ||
              a.reason.contains('Slow network'),
        ),
        isTrue,
      );
      expect(monitor.currentCacheSecs, greaterThan(120));
      monitor.stop();
    });

    test('缓存秒数增档时同步增大字节上限，避免旧 byte cap 成为瓶颈', () async {
      final adjustments = <CacheAdjustment>[];
      const bitrate = 40.0;
      final initialBytes = (bitrate * 120 * 125000 * 1.3).round();
      final monitor = makeMonitor(
        bitrateMbps: bitrate,
        initialMax: initialBytes,
        memoryBudgetBytes: 2 * 1024 * 1024 * 1024,
        onAdjustment: adjustments.add,
      );
      writeStatusFull(speedKbps: 1000);
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(monitor.currentCacheSecs, greaterThan(120));
      expect(monitor.currentDemuxerMaxBytes, greaterThan(initialBytes));
      expect(
        adjustments.any(
          (a) => a.cacheSecs != null && a.demuxerMaxBytes != null,
        ),
        isTrue,
        reason: 'seconds 与 bytes 必须作为同一条调整原子发出',
      );
      monitor.stop();
    });

    test('字节预算不足时日志同时显示请求目标、估算可达时长和限制来源', () async {
      final logs = <String>[];
      const byteCap = 1258670080;
      final monitor = makeMonitor(
        bitrateMbps: 56,
        initialSecs: 240,
        initialMax: byteCap,
        memoryBudgetBytes: byteCap,
        maxCacheSecs: 600,
        logs: logs,
      );
      writeStatusFull(speedKbps: 200, cacheIdle: '0');
      await monitor.sampleOnce();
      await monitor.sampleOnce();

      final output = logs.join('\n');
      expect(output, contains('cache target requested='));
      expect(output, contains('estimated-reachable=138s'));
      expect(output, contains('byte-cap=1.17GiB'));
      expect(output, contains('required='));
      expect(output, contains('(policy-memory-budget limited)'));
      expect(output, isNot(contains('buffer target')));
      expect(monitor.currentDemuxerMaxBytes, byteCap);
      monitor.stop();
    });

    test('策略允许 600s 时，中性网络不得被硬编码 300s 反向砍半', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        initialSecs: 600,
        initialMax: 1024 * 1024 * 1024,
        maxCacheSecs: 600,
        onAdjustment: adjustments.add,
      );
      writeStatusFull(speedKbps: 6000);
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(monitor.currentCacheSecs, 600);
      expect(adjustments, isEmpty);
      monitor.stop();
    });

    test('增档有上限 300s', () async {
      final monitor = makeMonitor(bitrateMbps: 40, initialSecs: 300);
      writeStatus(speedKbps: 1000);
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(monitor.currentCacheSecs, 300);
      monitor.stop();
    });

    test('速度满足需求时不做调整', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: 40, // 需求 5MB/s
        onAdjustment: adjustments.add,
      );
      writeStatus(speedKbps: 6000); // 6MB/s > 需求
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(adjustments, isEmpty);
      monitor.stop();
    });

    test('paused-for-cache 持续为真时直接驱动增档', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      // 用户场景：速度指标巨大（本地缓存读速）但 buffering=100。
      writeStatusFull(
        buffering: 100,
        speedKbps: 3000000,
        pausedForCache: '1',
      ); // 3GB/s 本地读速
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(
        adjustments.any((a) => a.reason.contains('Buffering')),
        isTrue,
        reason: '持续缓冲应触发增档（无论速度指标多大）',
      );
      expect(monitor.currentCacheSecs, greaterThan(120));
      monitor.stop();
    });

    test('持续缓冲达警告阈值 → 中文警告；恢复播放后清零', () async {
      final warnings = <String>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        bufferingWarningStreak: 3, // 缩短测试（3 次采样 = 15s）
        onWarning: warnings.add,
      );
      writeStatusFull(buffering: 100, speedKbps: 6000, pausedForCache: '1');
      for (var i = 0; i < 3; i++) {
        await monitor.sampleOnce();
      }
      expect(warnings, isNotEmpty);
      expect(warnings.first, contains('网络带宽不足以流畅播放'));
      // 恢复播放（buffering=0）→ 连续计数清零，再次缓冲重新计时。
      writeStatusFull(buffering: 0, speedKbps: 6000);
      await monitor.sampleOnce();
      writeStatusFull(buffering: 100, speedKbps: 6000, pausedForCache: '1');
      await monitor.sampleOnce();
      // 60s 去重窗口内不会重复弹（同一 _lastWarningAt）。
      expect(warnings.length, 1);
      monitor.stop();
    });

    test('码率未知时走绝对阈值判定（高速不误报）', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: null,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      // 速度远高于绝对阈值（512KB/s）→ 不调整。
      writeStatus(speedKbps: 3000);
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(adjustments, isEmpty);
      monitor.stop();
    });

    test('速度持续严重不足 → 用户警告（60 秒去重）', () async {
      final warnings = <String>[];
      final monitor = makeMonitor(bitrateMbps: 40, onWarning: warnings.add);
      writeStatus(speedKbps: 500); // 0.5MB/s < 5MB/s×0.3
      // 4 次采样触发 2 次警告判定，但 60 秒内去重 → 只有 1 次。
      for (var i = 0; i < 4; i++) {
        await monitor.sampleOnce();
      }
      expect(warnings, isNotEmpty);
      expect(warnings.length, 1);
      expect(warnings.first, contains('网络带宽不足以流畅播放'));
      monitor.stop();
    });

    test('警告冷却配置化：warningCooldown 归零时不限频', () async {
      final warnings = <String>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        warningCooldown: Duration.zero,
        onWarning: warnings.add,
      );
      writeStatus(speedKbps: 500); // 严重不足
      // 4 次采样：streak 2/3/4 各触发一次判定，冷却为 0 → 3 次都发。
      for (var i = 0; i < 4; i++) {
        await monitor.sampleOnce();
      }
      expect(warnings.length, 3, reason: '冷却归零不限制重复告警');
      monitor.stop();
    });

    test('状态文件少于 8 行（旧版 mpv）→ 网络部分降级，内存仍生效', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(800 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      writeStatus(lines: 5); // 旧 5 行格式：无网络字段
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      // 内存压力仍触发降级。
      expect(adjustments, isNotEmpty);
      expect(adjustments.first.demuxerMaxBytes, 512 * 1024 * 1024);
      monitor.stop();
    });
  });

  group('卡顿记录', () {
    test('一段连续 paused-for-cache 只累计一次卡顿事件', () async {
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
      );
      writeStatus(buffering: 60);
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(monitor.stallCount, 1);
      writeStatus(buffering: 0);
      await monitor.sampleOnce();
      expect(monitor.stallCount, 1, reason: '正常播放不计卡顿');
      monitor.stop();
    });
  });

  group('生命周期', () {
    test('stop 后不再采样（定时器取消）', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        memory: const _FakeMemory(800 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      monitor.stop();
      await monitor.sampleOnce(); // 手动驱动仍会采样（公开测试钩子）
      // stop 后 start 再次调用可重新启用（幂等替换）。
      monitor.start(
        statusFilePath: statusFile.path,
        initialDemuxerMaxBytes: 1024 * 1024 * 1024,
        initialCacheSecs: 120,
        bitrateMbps: null,
      );
      expect(monitor.currentDemuxerMaxBytes, 1024 * 1024 * 1024);
      monitor.stop();
    });

    test('状态文件不存在 → 采样无副作用', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        memory: const _FakeMemory(800 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      // 不写状态文件。
      await monitor.sampleOnce();
      expect(adjustments, isEmpty);
      monitor.stop();
    });
  });

  group('结尾/暂停/全缓存不误报（修复播完速度为 0 误报）', () {
    test('播放到结尾（time-pos 接近 duration）速度为 0 不触发网络不足', () async {
      final adjustments = <CacheAdjustment>[];
      final warnings = <String>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        onAdjustment: adjustments.add,
        onWarning: warnings.add,
      );
      // 播到结尾：time-pos 7199 / duration 7200，速度 0。
      writeStatusFull(timePos: 7199, speedKbps: 0);
      for (var i = 0; i < 4; i++) {
        await monitor.sampleOnce();
      }
      expect(adjustments, isEmpty, reason: '播到结尾速度 0 不应触发增档');
      expect(warnings, isEmpty, reason: '播到结尾速度 0 不应触发用户警告');
      monitor.stop();
    });

    test('暂停时速度为 0 不触发网络不足', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      writeStatusFull(paused: '1', speedKbps: 0);
      for (var i = 0; i < 3; i++) {
        await monitor.sampleOnce();
      }
      expect(adjustments, isEmpty, reason: '暂停时速度 0 不应触发增档');
      monitor.stop();
    });

    test('暂停瞬间残留 buffering 不计卡顿（顺序修正：先清零再统计）', () async {
      final warnings = <String>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        bufferingWarningStreak: 3,
        onWarning: warnings.add,
      );
      // 暂停 + buffering=100 残留（暂停瞬间状态文件写入）。
      writeStatusFull(paused: '1', buffering: 100, speedKbps: 0);
      for (var i = 0; i < 4; i++) {
        await monitor.sampleOnce();
      }
      expect(monitor.stallCount, 0, reason: '暂停时缓冲残留不计卡顿');
      expect(warnings, isEmpty, reason: '暂停时缓冲残留不触发持续缓冲警告');
      monitor.stop();
    });

    test('并发 sampleOnce 串行化：不重复评估', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(800 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      writeStatusFull(speedKbps: 1000, cacheIdle: '0');
      // 并发 3 次采样：串行化标志应使只有一次真正执行。
      await Future.wait([
        monitor.sampleOnce(),
        monitor.sampleOnce(),
        monitor.sampleOnce(),
      ]);
      // 单次采样最多触发一次调整（streak 1 不触发增档；Layer3 需 2 样本）。
      expect(adjustments.length, lessThanOrEqualTo(1));
      monitor.stop();
    });

    test('stop 后迟到的采样不产生回调（代际令牌）', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(800 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      writeStatusFull(speedKbps: 1000, cacheIdle: '0');
      await monitor.sampleOnce(); // 正常采样
      monitor.stop();
      // stop 后手动驱动采样：状态文件路径已清空 → 无副作用。
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(adjustments.length, lessThanOrEqualTo(1));
      monitor.stop();
    });

    test('缓存范围覆盖文件头尾时速度为 0 不误报', () async {
      final adjustments = <CacheAdjustment>[];
      final warnings = <String>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        fileSizeBytes: 200 * 1024 * 1024, // 200MB 文件
        onAdjustment: adjustments.add,
        onWarning: warnings.add,
      );
      writeStatusFull(speedKbps: 0, bofCached: '1', eofCached: '1');
      for (var i = 0; i < 4; i++) {
        await monitor.sampleOnce();
      }
      expect(adjustments, isEmpty, reason: '全缓存后速度 0 不应触发增档');
      expect(warnings, isEmpty, reason: '全缓存后速度 0 不应触发警告');
      monitor.stop();
    });

    test('0.41 场景：cache-idle=yes + 速度 0 → 不误报', () async {
      // 用户复现场景：mpv 0.41 下 cache-idle 属性已改名 demuxer-cache-idle，
      // 旧脚本读不到（null）会让 idle 分支失效。
      // cacheIdle=true 时零速属于缓存空闲，不应判定为网络不足。
      final adjustments = <CacheAdjustment>[];
      final warnings = <String>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        fileSizeBytes: 1024 * 1024 * 1024, // 1GB 文件，播放到后半段
        onAdjustment: adjustments.add,
        onWarning: warnings.add,
      );
      // 后半段（timePos 3000/7200，未到结尾 5s）：文件已下载完（EOF），
      // 缓存速度归 0，idle=yes（0.41 demuxer-cache-idle）。
      writeStatusFull(timePos: 3000, speedKbps: 0, cacheIdle: '1');
      for (var i = 0; i < 4; i++) {
        await monitor.sampleOnce();
      }
      expect(adjustments, isEmpty, reason: '全缓存（idle=yes）速度 0 不应触发增档');
      expect(warnings, isEmpty, reason: '全缓存（idle=yes）速度 0 不应触发警告');
      monitor.stop();
    });

    test('播放中缓存满时序：正常下载（idle=0）→ 缓存满（idle=1 速度 0）streak 清零不误报', () async {
      final adjustments = <CacheAdjustment>[];
      final warnings = <String>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        fileSizeBytes: 1024 * 1024 * 1024,
        onAdjustment: adjustments.add,
        onWarning: warnings.add,
      );
      // 阶段 1：正常下载，idle=0（正在读数据），速度 56Mbps > 码率×1.2
      // （48Mbps 阈值）→ 不判不足；Layer3 factor=56/40=1.4 中性保持。
      writeStatusFull(speedKbps: 7000, cacheIdle: '0');
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(adjustments, isEmpty, reason: '正常下载阶段不应有调整');
      // 阶段 2：缓存满/下载完，idle=1，速度衰减到 0 → 旧 streak 清零、不误报。
      writeStatusFull(speedKbps: 0, cacheIdle: '1');
      for (var i = 0; i < 4; i++) {
        await monitor.sampleOnce();
      }
      expect(adjustments, isEmpty, reason: '缓存满后速度 0 不应触发增档');
      expect(warnings, isEmpty, reason: '缓存满后速度 0 不应触发警告');
      monitor.stop();
    });

    test('网络检查暂停日志明确输出 cache-idle 原因和完整状态', () async {
      final logs = <String>[];
      final monitor = makeMonitor(bitrateMbps: 40, logs: logs);
      // 先制造一次未达到触发阈值的低速 streak，再进入 cache-idle。
      writeStatusFull(speedKbps: 1000, cacheIdle: '0');
      await monitor.sampleOnce();
      writeStatusFull(speedKbps: 0, cacheIdle: '1');
      await monitor.sampleOnce();

      final output = logs.join('\n');
      expect(output, contains('network check paused: reason=cache-idle'));
      expect(output, contains('paused=false'));
      expect(output, contains('fullyCached=false'));
      expect(output, contains('cacheIdle=true'));
      monitor.stop();
    });

    test('buffering=100 且 cache-idle=true（缓存满，下载追上播放）→ 不误报', () async {
      final adjustments = <CacheAdjustment>[];
      final warnings = <String>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        bufferingWarningStreak: 3,
        onAdjustment: adjustments.add,
        onWarning: warnings.add,
      );
      // 用户场景：速度正常、缓存保持满（buffering=100 + idle=1）。
      writeStatusFull(buffering: 100, speedKbps: 5000, cacheIdle: '1');
      for (var i = 0; i < 4; i++) {
        await monitor.sampleOnce();
      }
      expect(adjustments, isEmpty, reason: '缓存满不应触发增档');
      expect(warnings, isEmpty, reason: '缓存满不应触发卡顿警告');
      expect(monitor.stallCount, 0);
      monitor.stop();
    });

    test('paused-for-cache=true 才计为卡顿，idle 不参与推断', () async {
      final warnings = <String>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        bufferingWarningStreak: 3,
        onWarning: warnings.add,
      );
      writeStatusFull(
        buffering: 100,
        speedKbps: 100,
        cacheIdle: '0',
        pausedForCache: '1',
      );
      for (var i = 0; i < 3; i++) {
        await monitor.sampleOnce();
      }
      // 一段连续 paused-for-cache 只算一次用户可感知的卡顿事件。
      expect(monitor.stallCount, 1, reason: '连续卡顿只计一个事件');
      // 且网络判定活动（极低速触发网络警告）。
      expect(warnings, isNotEmpty);
      monitor.stop();
    });

    test('旧 7 行格式（无 cache-idle）→ buffering=100 按「未知」保守不误报', () async {
      final warnings = <String>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        bufferingWarningStreak: 3,
        onWarning: warnings.add,
      );
      // 7 行（无 idle 行）：buffering=100 但 idle 未知 → 不视为卡顿。
      writeStatus(buffering: 100, speedKbps: 5000, lines: 7);
      for (var i = 0; i < 3; i++) {
        await monitor.sampleOnce();
      }
      expect(warnings, isEmpty, reason: 'idle 未知时保守不误报');
      monitor.stop();
    });
  });

  group('真实带宽测速 + Layer 3 网络系数（设计文档第 8 节）', () {
    test('带宽充足（Factor > 3）→ 适度降档（-20%）', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      // 速度 5000KB/s ≈ 40Mbps → Factor = 40/40 = 1.0？不——需要 >3：
      // 带宽 = speed×8/1000 Mbps；5000KB/s = 40Mbps → Factor 1.0 保持。
      // 用 15000KB/s = 120Mbps → Factor 3.0（=rich 不触发 >3）→ 用 20000。
      writeStatusFull(speedKbps: 20000); // 160Mbps / 40Mbps = 4.0 > 3
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      final l3 = adjustments.where((a) => a.reason.contains('Layer3'));
      expect(l3, isNotEmpty, reason: '带宽估计就绪后应应用 Layer 3');
      // Layer 3 调整本身：120 × 0.8 = 96s（随后 Slow network 可能继续增档）。
      expect(l3.first.cacheSecs, 96);
      expect(monitor.currentCacheSecs, lessThan(120));
      monitor.stop();
    });

    test('带宽不足（Factor < 1）→ 增档（+50%），上限 300s 封顶', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      writeStatusFull(speedKbps: 1000); // 8Mbps / 40Mbps = 0.2 < 1
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      final l3 = adjustments.where((a) => a.reason.contains('Layer3'));
      expect(l3, isNotEmpty);
      // Layer 3 调整本身：120 × 1.5 = 180s（随后 Slow network 可能继续增档）。
      expect(l3.first.cacheSecs, 180);
      expect(monitor.currentCacheSecs, inInclusiveRange(180, 300));
      monitor.stop();
    });

    test('带宽适中（1 ≤ Factor ≤ 3）→ 保持不调整', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      writeStatusFull(speedKbps: 6000); // 48Mbps / 40Mbps = 1.2
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(
        adjustments.where((a) => a.reason.contains('Layer3')),
        isEmpty,
        reason: 'Factor 1~3 保持默认',
      );
      expect(monitor.currentCacheSecs, 120);
      monitor.stop();
    });

    test('带宽样本波动大（max > min×2）时不应用 Layer 3（等待稳定）', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: 40,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      writeStatusFull(speedKbps: 1000);
      await monitor.sampleOnce();
      writeStatusFull(speedKbps: 9000);
      await monitor.sampleOnce();
      expect(
        adjustments.where((a) => a.reason.contains('Layer3')),
        isEmpty,
        reason: '波动过大时不估算带宽',
      );
      monitor.stop();
    });
  });

  group('码率未知时绝对阈值兜底（修复限速后无提示）', () {
    test('码率未知 + 速度持续低于绝对阈值 → 增档与警告均触发', () async {
      final adjustments = <CacheAdjustment>[];
      final warnings = <String>[];
      final monitor = makeMonitor(
        bitrateMbps: null, // 首次播放：码率未就绪
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        onAdjustment: adjustments.add,
        onWarning: warnings.add,
      );
      // 100KB/s < 512KB/s（poor 绝对阈值）且 < 256KB/s（critical）。
      writeStatusFull(speedKbps: 100);
      for (var i = 0; i < 4; i++) {
        await monitor.sampleOnce();
      }
      expect(
        adjustments.any((a) => a.reason.contains('Slow network')),
        isTrue,
        reason: '码率未知时仍应触发增档（绝对阈值兜底）',
      );
      expect(warnings, isNotEmpty, reason: '码率未知时仍应触发用户警告');
      expect(warnings.first, contains('网络带宽不足以流畅播放'));
      monitor.stop();
    });

    test('updateBitrate 后切换为相对码率判定', () async {
      final adjustments = <CacheAdjustment>[];
      final monitor = makeMonitor(
        bitrateMbps: null,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        onAdjustment: adjustments.add,
      );
      // 码率未知 + 速度 300KB/s（< 512 绝对阈值）→ 触发绝对判定。
      writeStatusFull(speedKbps: 300);
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(adjustments.any((a) => a.reason.contains('Slow network')), isTrue);
      // 码率就绪（40Mbps，需求 5MB/s）：300KB/s 仍不足 → 继续判定；
      // 更新后计数重置，需重新累计 2 次。
      monitor.updateBitrate(40);
      adjustments.clear();
      writeStatusFull(speedKbps: 300);
      await monitor.sampleOnce();
      await monitor.sampleOnce();
      expect(
        adjustments.any(
          (a) =>
              a.reason.contains('Layer3 network factor') ||
              a.reason.contains('Slow network'),
        ),
        isTrue,
        reason: 'updateBitrate 后按相对码率判定',
      );
      monitor.stop();
    });

    test('码率未知但速度高于绝对阈值 → 不误报', () async {
      final adjustments = <CacheAdjustment>[];
      final warnings = <String>[];
      final monitor = makeMonitor(
        bitrateMbps: null,
        memory: const _FakeMemory(16 * 1024 * 1024 * 1024),
        onAdjustment: adjustments.add,
        onWarning: warnings.add,
      );
      writeStatusFull(speedKbps: 3000); // 3MB/s > 512KB/s
      for (var i = 0; i < 3; i++) {
        await monitor.sampleOnce();
      }
      expect(adjustments, isEmpty);
      expect(warnings, isEmpty);
      monitor.stop();
    });
  });
}

/// 可控内存 fake。
class _FakeMemory implements SystemMemoryProvider {
  const _FakeMemory(this.available);

  final int? available;

  @override
  Future<int?> availableMemoryBytes() async => available;
}
