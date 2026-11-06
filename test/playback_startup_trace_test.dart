import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/playback_startup_trace.dart';
import 'package:streampath/domain/services/mpv_scripts.dart';

void main() {
  test('诊断脱敏覆盖认证、查询令牌、任意脚本参数及异常选项名', () {
    final args = PlaybackStartupTrace.redactArgs([
      'https://user:password@host/media.ts?token=secret',
      '--http-header-fields=Authorization: Bearer secret',
      '--script-opts=token=secret',
      '--https://user:password@host?token=secret',
      '--cache=yes',
      '--cache-secs=30',
      '--demuxer-max-bytes=134217728',
    ]);
    final text = args.join(' ');
    for (final secret in ['password', 'secret', 'user:', 'host', 'Bearer']) {
      expect(text, isNot(contains(secret)));
    }
    expect(args, containsAll(['--cache=yes', '--cache-secs=30']));
  });

  test('并发追踪独立、嵌套复用、异常保留且退出后不泄漏 Zone', () async {
    final base = await Directory.systemTemp.createTemp('startup_trace_');
    final traces = <PlaybackStartupTrace>[];
    try {
      await Future.wait(
        List.generate(2, (index) {
          return PlaybackStartupTrace.run(() async {
            final trace = PlaybackStartupTrace.current!;
            traces.add(trace);
            await PlaybackStartupTrace.run(() async {
              expect(identical(PlaybackStartupTrace.current, trace), isTrue);
            });
            trace.mark('processCreated', {'pid': index});
          }, outputDirectory: base);
        }),
      );
      await Future.wait(traces.map((t) => t.flushed));
      expect(traces.map((t) => t.id).toSet(), hasLength(2));
      expect(PlaybackStartupTrace.current, isNull);
      for (final file in base.listSync().whereType<File>()) {
        final records = file.readAsLinesSync().map((s) => jsonDecode(s) as Map);
        expect(records.first['event'], 'userClick');
        expect(records.first['proxy'], true);
        expect(records.last['event'], 'preparationReturned');
        expect(
          records.where((r) => r['event'] == 'processCreated'),
          hasLength(1),
        );
      }
      late PlaybackStartupTrace failedTrace;
      await expectLater(
        PlaybackStartupTrace.run(() async {
          failedTrace = PlaybackStartupTrace.current!;
          throw StateError('expected');
        }, outputDirectory: base),
        throwsStateError,
      );
      await failedTrace.flushed;
    } finally {
      await base.delete(recursive: true);
    }
  });

  test('MPV 可选诊断仅采集白名单属性，不记录媒体地址或冒充首帧', () async {
    final base = await Directory.systemTemp.createTemp('startup_lua_');
    try {
      final path = await MpvScripts.ensureStartupTrace(
        '${base.path}/events.jsonl',
        base,
        sessionId: 'test',
      );
      final source = await File(path).readAsString();
      expect(source, contains("snapshot('mpvPlaybackRestart')"));
      expect(source, contains("record.proxy = true"));
      expect(source, isNot(contains("get_property('path'")));
      expect(source, isNot(contains('firstVideoFrame')));
      expect(source, contains('ticks >= 120'));
    } finally {
      await base.delete(recursive: true);
    }
  });
}
