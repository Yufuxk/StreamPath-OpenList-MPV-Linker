import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/models/audio_media_entry.dart';
import '../../data/models/player_config.dart';
import 'audio_lyrics_localizer.dart';
import 'audio_mpv_scripts.dart';

/// 将音频会话已取得的 LRC 转为由 MPV 自行计时的 ASS 歌词轨道。
class AudioLyricsAssRenderer {
  const AudioLyricsAssRenderer();

  static final RegExp _lineTime = RegExp(r'^\[(\d+):([0-5]?\d)\.(\d{2,3})\]');
  static final RegExp _enhancedTime = RegExp(r'<(\d+):([0-5]?\d)\.(\d{2,3})>');
  static final RegExp _inlineTime = RegExp(r'\[(\d+):([0-5]?\d)\.(\d{2,3})\]');
  static final RegExp _offset = RegExp(
    r'^\[offset:([+-]?\d+)\]$',
    caseSensitive: false,
  );

  Future<AudioLyricsLocalizationResult> prepare({
    required AudioLyricsLocalizationResult localized,
    required Directory base,
    required String sessionId,
    int startIndex = 0,
    DateTime? deadline,
    String fontFamily = PlayerConfig.defaultAudioLyricsFontFamily,
    double outlineWidth = PlayerConfig.defaultAudioLyricsOutlineWidth,
    double transparency = PlayerConfig.defaultAudioLyricsTransparency,
  }) async {
    final entries = localized.entries.toList();
    final files = localized.sessionFiles.toList();
    final indices = [
      if (startIndex >= 0 && startIndex < entries.length) startIndex,
      for (var i = 0; i < entries.length; i++)
        if (i != startIndex) i,
    ];
    for (final index in indices) {
      if (deadline != null && !DateTime.now().isBefore(deadline)) break;
      final lyric = entries[index].lyrics;
      if (lyric == null) continue;
      final source = File(lyric.url);
      final target = File(
        p.join(
          base.path,
          'streampath-audio-lyrics-${AudioMpvScripts.safeSessionToken(sessionId)}-$index.ass',
        ),
      );
      try {
        if (await source.length() > AudioLyricsLocalizer.maxLyricsBytes) {
          continue;
        }
        final ass = render(
          utf8.decode(await source.readAsBytes()),
          fontFamily: fontFamily,
          outlineWidth: outlineWidth,
          transparency: transparency,
        );
        if (ass == null) continue;
        await target.writeAsString(ass, encoding: utf8, flush: true);
        files.add(target);
        entries[index] = entries[index].copyWith(
          lyrics: AudioCompanionFile(name: lyric.name, url: target.path),
        );
      } on FileSystemException catch (error) {
        // 外部歌词读取或会话文件写入失败时保留原 LRC。
        stderr.writeln(
          'Audio lyrics conversion failed for playlist item $index: ${error.runtimeType}',
        );
      } on FormatException catch (error) {
        // 无法按 UTF-8 解析时交给 MPV 原有的 LRC 路径。
        stderr.writeln(
          'Audio lyrics conversion failed for playlist item $index: ${error.runtimeType}',
        );
      }
    }
    return AudioLyricsLocalizationResult(
      entries: List.unmodifiable(entries),
      sessionFiles: List.unmodifiable(files),
    );
  }

  /// 返回 null 表示没有可用时间轴，调用方继续加载原 LRC。
  String? render(
    String lrc, {
    String fontFamily = PlayerConfig.defaultAudioLyricsFontFamily,
    double outlineWidth = PlayerConfig.defaultAudioLyricsOutlineWidth,
    double transparency = PlayerConfig.defaultAudioLyricsTransparency,
  }) {
    final lines = <_LyricLine>[];
    final sourceLines = lrc.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'));
    var offset = 0;
    for (final sourceLine in sourceLines) {
      final match = _offset.firstMatch(sourceLine.trim());
      if (match != null) offset = int.parse(match.group(1)!);
    }
    var order = 0;
    for (final raw in sourceLines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (_offset.hasMatch(line)) continue;
      var rest = line;
      final starts = <int>[];
      while (true) {
        final match = _lineTime.firstMatch(rest);
        if (match == null) break;
        starts.add(_milliseconds(match) - offset);
        rest = rest.substring(match.end);
      }
      if (starts.isEmpty || rest.trim().isEmpty) continue;
      for (final start in starts) {
        final words = _words(rest, start, offset);
        lines.add(_LyricLine(start < 0 ? 0 : start, rest, words, order++));
      }
      if (lines.length > 4000) return null;
    }
    if (lines.isEmpty) return null;
    lines.sort((a, b) {
      final time = a.start.compareTo(b.start);
      return time != 0 ? time : a.order.compareTo(b.order);
    });

    final groups = <_LyricGroup>[];
    for (final line in lines) {
      if (groups.isEmpty || groups.last.start != line.start) {
        groups.add(_LyricGroup(line.start, [line]));
      } else {
        groups.last.lines.add(line);
      }
    }

    final font = fontFamily.replaceAll(RegExp(r'[,\r\n]'), ' ').trim();
    final selectedFont = font.isEmpty
        ? PlayerConfig.defaultAudioLyricsFontFamily
        : font;
    final outline = outlineWidth
        .clamp(0.0, PlayerConfig.maxAudioLyricsOutlineWidth)
        .toStringAsFixed(1);
    final visibleOpacity = 1 - transparency.clamp(0.0, 1.0);
    final textAlpha = ((1 - visibleOpacity) * 255)
        .round()
        .toRadixString(16)
        .padLeft(2, '0')
        .toUpperCase();
    final backgroundAlpha = (255 - visibleOpacity * 127)
        .round()
        .toRadixString(16)
        .padLeft(2, '0')
        .toUpperCase();
    final out = StringBuffer('''[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Current,$selectedFont,48,&H${textAlpha}FFFFFF,&H${textAlpha}A0A0A0,&H${textAlpha}101010,&H${backgroundAlpha}000000,1,0,0,0,100,100,0,0,1,$outline,1,5,40,40,20,1
Style: Auxiliary,$selectedFont,30,&H${textAlpha}DDDDDD,&H${textAlpha}DDDDDD,&H${textAlpha}101010,&H${backgroundAlpha}000000,0,0,0,0,100,100,0,0,1,$outline,1,5,40,40,20,1
Style: Context,$selectedFont,30,&H${textAlpha}999999,&H${textAlpha}999999,&H${textAlpha}101010,&H${backgroundAlpha}000000,0,0,0,0,100,100,0,0,1,$outline,1,5,40,40,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''');

    for (var i = 0; i < groups.length; i++) {
      final group = groups[i];
      final start = group.start;
      final nextStart = i + 1 < groups.length ? groups[i + 1].start : null;
      final lastWordEnd = group.lines
          .expand((line) => line.words)
          .map((word) => word.end ?? word.start)
          .fold<int>(start, (a, b) => b > a ? b : a);
      final end =
          nextStart ??
          (lastWordEnd > start + 6000 ? lastWordEnd : start + 6000);
      if (end <= start) continue;
      final primary = group.primary;
      final body = primary.words.isEmpty
          ? _escape(primary.text)
          : _karaoke(primary.words, start, end, textAlpha);
      final others = group.lines
          .where((line) => !identical(line, primary))
          .take(2)
          .toList();
      const centerY = 360;
      const mainHalfHeight = 24;
      const auxiliaryHalfHeight = 15;
      const firstAuxiliaryOffset = 48;
      const auxiliaryStep = 36;
      const contextGap = 75;
      final lastAuxiliaryOffset = others.isEmpty
          ? 0
          : firstAuxiliaryOffset + (others.length - 1) * auxiliaryStep;
      final bottomOffset = others.isEmpty
          ? mainHalfHeight
          : lastAuxiliaryOffset + auxiliaryHalfHeight;
      final mainY = centerY - ((bottomOffset - mainHalfHeight) / 2).round();
      _event(out, start, end, 'Current', mainY, body);
      for (var j = 0; j < others.length; j++) {
        _event(
          out,
          start,
          end,
          'Auxiliary',
          mainY + firstAuxiliaryOffset + j * auxiliaryStep,
          _escape(others[j].displayText),
        );
      }
      if (i > 0) {
        _event(
          out,
          start,
          end,
          'Context',
          mainY - mainHalfHeight - auxiliaryHalfHeight - contextGap,
          _escape(groups[i - 1].primary.displayText),
        );
      }
      if (i + 1 < groups.length) {
        _event(
          out,
          start,
          end,
          'Context',
          mainY + bottomOffset + auxiliaryHalfHeight + contextGap,
          _escape(groups[i + 1].primary.displayText),
        );
      }
    }
    return out.toString();
  }

  static List<_LyricWord> _words(String text, int start, int offset) {
    final enhanced = _enhancedTime.allMatches(text).toList();
    if (enhanced.isNotEmpty && enhanced.first.start == 0) {
      final words = <_LyricWord>[];
      for (var i = 0; i < enhanced.length; i++) {
        final current = enhanced[i];
        final next = i + 1 < enhanced.length ? enhanced[i + 1] : null;
        final value = text.substring(current.end, next?.start ?? text.length);
        if (value.isEmpty) continue;
        words.add(
          _LyricWord(
            _milliseconds(current) - offset,
            next == null ? null : _milliseconds(next) - offset,
            value,
          ),
        );
      }
      return words;
    }
    final inline = _inlineTime.allMatches(text).toList();
    if (inline.isEmpty) return const [];
    final words = <_LyricWord>[];
    var cursor = start;
    var textStart = 0;
    for (final marker in inline) {
      final value = text.substring(textStart, marker.start);
      final end = _milliseconds(marker) - offset;
      if (value.isNotEmpty) words.add(_LyricWord(cursor, end, value));
      cursor = end;
      textStart = marker.end;
    }
    final tail = text.substring(textStart);
    if (tail.isNotEmpty) words.add(_LyricWord(cursor, null, tail));
    return words;
  }

  static int _milliseconds(RegExpMatch match) {
    final minute = int.parse(match.group(1)!);
    final second = int.parse(match.group(2)!);
    final fraction = match.group(3)!;
    return minute * 60000 +
        second * 1000 +
        int.parse(fraction) * (fraction.length == 2 ? 10 : 1);
  }

  static String _karaoke(
    List<_LyricWord> words,
    int start,
    int end,
    String textAlpha,
  ) {
    final out = StringBuffer();
    var cursor = start;
    for (final word in words) {
      final from = word.start.clamp(cursor, end);
      if (from > cursor) {
        out.write(
          '{\\1a&HFF&\\k${(from - cursor) ~/ 10}}\u200B{\\1a&H$textAlpha&}',
        );
      }
      final until = (word.end ?? (from + 10)).clamp(from, end);
      out.write(
        '{\\kf${((until - from) ~/ 10).clamp(1, 999999)}}${_escape(word.text)}',
      );
      cursor = until;
    }
    return out.toString();
  }

  static void _event(
    StringBuffer out,
    int start,
    int end,
    String style,
    int y,
    String text,
  ) {
    if (text.trim().isEmpty) return;
    out.writeln(
      'Dialogue: 0,${_assTime(start)},${_assTime(end)},$style,,0,0,0,,{\\an5\\move(640,${y + 24},640,$y,0,300)\\fad(180,180)}$text',
    );
  }

  static String _assTime(int milliseconds) {
    final centiseconds = milliseconds ~/ 10;
    final hours = centiseconds ~/ 360000;
    final minutes = (centiseconds ~/ 6000) % 60;
    final seconds = (centiseconds ~/ 100) % 60;
    final fraction = centiseconds % 100;
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${fraction.toString().padLeft(2, '0')}';
  }

  static String _escape(String value) => value
      .replaceAll('\\', '＼')
      .replaceAll('{', '｛')
      .replaceAll('}', '｝')
      .replaceAll(RegExp(r'[\r\n]'), ' ');
}

class _LyricLine {
  const _LyricLine(this.start, this.text, this.words, this.order);
  final int start;
  final String text;
  final List<_LyricWord> words;
  final int order;

  String get displayText =>
      words.isEmpty ? text : words.map((word) => word.text).join();
}

class _LyricWord {
  const _LyricWord(this.start, this.end, this.text);
  final int start;
  final int? end;
  final String text;
}

class _LyricGroup {
  const _LyricGroup(this.start, this.lines);
  final int start;
  final List<_LyricLine> lines;

  _LyricLine get primary {
    final timed = lines.where((line) => line.words.isNotEmpty).toList();
    return timed.length == 1 ? timed.single : lines.first;
  }
}
