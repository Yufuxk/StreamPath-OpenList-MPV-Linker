import 'dart:convert';
import 'dart:math' as math;
import 'package:path/path.dart' as p;

/// 只负责评分；实际节目身份仍由播放器确认的 MPLS 决定。
class IsoSubtitleMatcher {
  static Map<String, dynamic>? describe(
    String path,
    String stem,
    int isoCount,
  ) {
    final name = p.posix.basenameWithoutExtension(path).toLowerCase();
    final explicit = RegExp(
      r'^(.*?)mpls(\d{5})(?:[._ -].*)?$',
    ).firstMatch(name);
    final prefixed =
        name == stem ||
        name.startsWith('$stem.') ||
        name.startsWith('$stem ') ||
        name.startsWith('$stem-') ||
        name.startsWith('${stem}_');
    String? mpls;
    if (explicit != null) {
      final prefix = explicit[1]!.replaceAll(RegExp(r'[._ -]+$'), '');
      if (prefix != stem && !(prefix.isEmpty && isoCount == 1)) return null;
      mpls = explicit[2];
    } else if (name.contains('mpls') || (!prefixed && isoCount != 1)) {
      return null;
    }
    final suffix = prefixed ? name.substring(stem.length) : name;
    final match = RegExp(
      r'(?:^|[\[\] ._\-])(?:s\d{1,2}e|ep?|第)?(\d{1,3})(?:话|話|集)?(?=$|[\[\] ._\-])',
    ).firstMatch(suffix);
    final episode = mpls == null && match != null ? int.parse(match[1]!) : null;
    bool token(String pattern) => RegExp(
      '(?:^|[\\[\\] ._\\-])(?:$pattern)(?=\u0024|[\\[\\] ._\\-])',
    ).hasMatch(name);
    final language =
        token('chs|sc|zh-cn|zh-hans') ||
            name.contains('简') ||
            name.contains('簡')
        ? 60
        : token('cht|tc|zh-tw|zh-hant') || name.contains('繁')
        ? 50
        : token('zh|chi|zho') || name.contains('中文')
        ? 40
        : token('ja|jpn|jp')
        ? 20
        : token('en|eng')
        ? 10
        : 0;
    return {
      'path': path,
      'mpls': mpls,
      'episode': episode,
      'base':
          language +
          (prefixed ? 40 : 0) +
          {'.ass': 3, '.ssa': 2, '.srt': 1}[p.posix
              .extension(path)
              .toLowerCase()]!,
    };
  }

  static double? duration(List<int> bytes, String path) {
    String text;
    if (bytes.length >= 2 &&
        ((bytes[0] == 255 && bytes[1] == 254) ||
            (bytes[0] == 254 && bytes[1] == 255))) {
      final little = bytes[0] == 255;
      text = String.fromCharCodes([
        for (var i = 2; i + 1 < bytes.length; i += 2)
          little
              ? bytes[i] | (bytes[i + 1] << 8)
              : (bytes[i] << 8) | bytes[i + 1],
      ]);
    } else {
      // 时间字段为 ASCII；旧编码的正文不参与评分，也不改写源字节。
      text = utf8.decode(bytes, allowMalformed: true);
    }
    double? timestamp(String value) {
      final match = RegExp(
        r'^(\d+):(\d{2}):(\d{2})[.,](\d{1,3})$',
      ).firstMatch(value.trim());
      if (match == null) return null;
      final minute = int.parse(match[2]!), second = int.parse(match[3]!);
      if (minute >= 60 || second >= 60) return null;
      return int.parse(match[1]!) * 3600 +
          minute * 60 +
          second +
          int.parse(match[4]!) / math.pow(10, match[4]!.length);
    }

    double last = 0;
    void accept(String start, String end) {
      final a = timestamp(start), b = timestamp(end);
      if (a != null && b != null && b > a) last = math.max(last, b);
    }

    if (p.posix.extension(path).toLowerCase() == '.srt') {
      for (final match in RegExp(
        r'^\s*(\d+:\d{2}:\d{2}[.,]\d{1,3})\s*-->\s*(\d+:\d{2}:\d{2}[.,]\d{1,3})',
        multiLine: true,
      ).allMatches(text)) {
        accept(match[1]!, match[2]!);
      }
    } else {
      var events = false;
      var fields = <String>[];
      for (final line in const LineSplitter().convert(text)) {
        final value = line.trim().replaceFirst('\ufeff', '');
        if (value.startsWith('[')) events = value.toLowerCase() == '[events]';
        if (!events) continue;
        if (value.toLowerCase().startsWith('format:')) {
          fields = value
              .substring(7)
              .toLowerCase()
              .split(',')
              .map((e) => e.trim())
              .toList();
        }
        if (!value.toLowerCase().startsWith('dialogue:')) continue;
        final parts = value.substring(9).split(',');
        final start = fields.indexOf('start'), end = fields.indexOf('end');
        if (start >= 0 && end >= 0 && parts.length >= fields.length) {
          accept(parts[start], parts[end]);
        }
      }
    }
    return last > 0 ? last : null;
  }

  static String? best(
    String id,
    List<Map<String, dynamic>> titles,
    List<Map<String, dynamic>> candidates,
  ) {
    final ids =
        titles
            .where((t) => (t['duration'] as num? ?? 0) >= 300)
            .map((t) => t['id'] as String)
            .toSet()
            .toList()
          ..sort();
    final episode = ids.indexOf(id) + 1;
    final video =
        (titles.where((t) => t['id'] == id).firstOrNull?['duration'] as num?)
            ?.toDouble() ??
        0;
    String? bestPath;
    double bestScore = -double.infinity;
    for (final candidate in candidates) {
      final explicit = candidate['mpls'];
      if (explicit != null && explicit != id) continue;
      final end = (candidate['duration'] as num?)?.toDouble() ?? 0;
      final tolerance = math.max(120.0, video * 0.1);
      final delta = (video - end).abs();
      final durationMatch =
          video > 0 && end > 0 && end <= video + 5 && delta <= tolerance;
      final episodeMatch = episode > 0 && candidate['episode'] == episode;
      if (explicit == null && !durationMatch && !episodeMatch) continue;
      final score =
          (candidate['base'] as num).toDouble() +
          (explicit != null ? 2000 : 0) +
          (durationMatch ? 600 * (1 - delta / tolerance) : 0) +
          (episodeMatch
              ? 200
              : candidate['episode'] != null
              ? -200
              : 0);
      final path = candidate['path'] as String;
      if (score > bestScore ||
          (score == bestScore &&
              (bestPath == null || path.compareTo(bestPath) < 0))) {
        bestScore = score;
        bestPath = path;
      }
    }
    return bestPath;
  }
}
