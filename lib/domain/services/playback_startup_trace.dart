import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 仅显式指定输出目录时启用；写盘不进入播放等待链。
class PlaybackStartupTrace {
  PlaybackStartupTrace._(this.base, this.id) {
    mark('userClick', {'proxy': true, 'source': 'playback-request-entry'});
    mark('firstVideoFrame', {'available': false});
  }

  final Directory base;
  final String id;
  final Stopwatch _clock = Stopwatch()..start();
  Future<void> _writes = Future.value();
  static final Object _zoneKey = Object();
  static int _sequence = 0;
  static PlaybackStartupTrace? get current =>
      Zone.current[_zoneKey] as PlaybackStartupTrace?;
  String get mpvOutput => p.join(base.path, '$id-mpv.jsonl');

  static Future<T> run<T>(
    Future<T> Function() operation, {
    Directory? outputDirectory,
  }) {
    if (current != null) return operation();
    final configured = Platform.environment['STREAMPATH_PLAYBACK_TRACE_DIR'];
    if (outputDirectory == null && (configured == null || configured.isEmpty)) {
      return operation();
    }
    final trace = PlaybackStartupTrace._(
      outputDirectory ?? Directory(configured!),
      'startup-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}',
    );
    return runZoned(() async {
      try {
        return await operation();
      } finally {
        trace.mark('preparationReturned');
      }
    }, zoneValues: {_zoneKey: trace});
  }

  void mark(String event, [Map<String, Object?> fields = const {}]) {
    if (_clock.elapsed > const Duration(minutes: 2)) return;
    final line = jsonEncode({
      'event': event,
      'elapsedUs': _clock.elapsedMicroseconds,
      'wallTimeUtc': DateTime.now().toUtc().toIso8601String(),
      ...fields,
    });
    _writes = _writes
        .then((_) async {
          await base.create(recursive: true);
          await File(
            p.join(base.path, '$id-dart.jsonl'),
          ).writeAsString('$line\n', mode: FileMode.append);
        })
        .catchError((Object error) {
          // 诊断目录不可写时保留播放行为，不输出可能带敏感路径的异常。
          stderr.writeln(
            'Playback startup trace write failed: ${error.runtimeType}',
          );
        });
  }

  /// 仅保留已知数值/枚举选项；URL、路径及任意自定义值不进入日志。
  static List<String> redactArgs(List<String> args) => [
    for (final arg in args)
      if (!arg.startsWith('--'))
        '<media-or-value>'
      else if (RegExp(
        r'^--(?:cache(?:-secs|-pause|-pause-initial|-pause-wait)?|demuxer-(?:max-bytes|max-back-bytes|seekable-cache|readahead-secs|lavf-probesize|lavf-analyzeduration|lavf-hacks)|force-seekable|rebase-start-time|start|fullscreen|vo|ao|hwdec|no-config|load-scripts)(?:=(?:yes|no|auto|null|[0-9]+(?:\.[0-9]+)?[kKmMgG]?))?$',
      ).hasMatch(arg))
        arg
      else
        '${_optionName(arg)}=<redacted>',
  ];

  static String _optionName(String arg) {
    final name = arg.split('=').first;
    return RegExp(r'^--[a-zA-Z0-9-]+$').hasMatch(name) ? name : '--option';
  }

  Future<void> get flushed => _writes;
}
