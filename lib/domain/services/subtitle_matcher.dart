import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../data/models/subtitle_item.dart';
import '../../data/models/web_dav_file.dart';

/// 字幕匹配算法。
///
/// 文件名去扩展名、小写后按 `.` `_` 空格切分为「段」，语言标签（如
/// `zh`、`chs`、`zh-Hans`、`en`）从尾部剥离后得到「核心名」：
///  1. **完全同名**：`movie.mkv` ↔ `movie.srt` —— 最高优先级；
///  2. **同名+语言后缀**：`movie.mkv` ↔ `movie.zh.srt` / `movie.chs.ass`；
///  3. **相似名称**：核心名互为**段前缀**（`My.Movie.chs.srt` ↔
///     `My.Movie.2024.1080p.BluRay.mkv`），或共享 ≥2 段且占较短者一半
///     以上的**公共段前缀**（`My.Series.01.chs.srt` ↔
///     `My.Series.S01E01.mkv`）；
///  4. 返回全部匹配项，按 完全同名 > 同名中文 > 相似中文 > 同名其他语言
///     > 相似无标签 > 相似其他语言 排序，[findBestFor] 取最佳单条。
class SubtitleMatcher {
  const SubtitleMatcher();

  /// 为具体视频/STRM 条目匹配字幕。
  ///
  /// 除名称规则外，候选字幕的 href 必须与 [video] 同源且父目录相同，
  /// 防止浏览状态异常或跨目录候选把字幕备份目录中的文件带入播放会话。
  List<SubtitleItem> matchFor(WebDavFile video, List<WebDavFile> siblings) {
    return _match(video.name, siblings, videoHref: video.href);
  }

  List<SubtitleItem> _match(
    String videoName,
    List<WebDavFile> siblings, {
    String? videoHref,
  }) {
    final videoCore = _stripLanguage(_segments(videoName)).core;

    final matches = <SubtitleItem>[];
    for (final f in siblings) {
      if (!f.isSubtitle) continue;
      if (videoHref != null && !_isSameDirectory(videoHref, f.href)) continue;
      final m = _matchCore(videoCore, _segments(f.name));
      if (m == null) continue;
      matches.add(
        SubtitleItem(
          name: f.name,
          url: f.href,
          language: m.language,
          score: m.score,
        ),
      );
    }

    matches.sort((a, b) {
      // 分数高的优先；同分时短的名称优先（"movie.zh.srt" 优于 "movie.zh.Hans.srt"）。
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.name.length.compareTo(b.name.length);
    });
    return matches;
  }

  /// 严格按具体视频/STRM 所在目录返回最佳字幕。
  SubtitleItem? findBestFor(WebDavFile video, List<WebDavFile> siblings) {
    final matches = matchFor(video, siblings);
    return matches.isEmpty ? null : matches.first;
  }

  // ── 内部 ─────────────────────────────────────────────────────

  /// 名称段：去扩展名、小写，按常见点号、空白、横线和括号切分。
  /// `zh-Hans` 等语言标签拆分后仍可由 zh/hans 两段连续剥离。
  static List<String> _segments(String fileName) => p
      .basenameWithoutExtension(fileName)
      .toLowerCase()
      .split(RegExp(r'[._\s\-\[\](){}\u2010-\u2015\u2212\uff0d]+'))
      .where((s) => s.isNotEmpty)
      .toList();

  /// 从尾部剥离语言标签段，返回核心名与语言分类（无标签为 null）。
  static _Stripped _stripLanguage(List<String> segs) {
    final core = [...segs];
    SubtitleLanguage? lang;
    while (core.isNotEmpty) {
      final l = _langOfSegment(core.last);
      if (l != null) {
        lang = l; // 多语言时取最靠近核心的标签（movie.zh.en.srt → chinese）
        core.removeLast();
        continue;
      }
      if (_subtitleQualifierTags.contains(core.last)) {
        core.removeLast();
        continue;
      }
      break;
    }
    return _Stripped(core, lang);
  }

  /// 判定单段是否为语言标签（支持 `zh-Hans` 连字符形式，取 `-` 前主标签）。
  static SubtitleLanguage? _langOfSegment(String seg) {
    final s = seg.toLowerCase();
    if (AppConstants.chineseLangTags.contains(s)) {
      return SubtitleLanguage.chinese;
    }
    if (AppConstants.otherLangTags.contains(s)) {
      return SubtitleLanguage.other;
    }
    final primary = s.split('-').first;
    if (AppConstants.chineseLangTags.contains(primary)) {
      return SubtitleLanguage.chinese;
    }
    if (AppConstants.otherLangTags.contains(primary)) {
      return SubtitleLanguage.other;
    }
    return null;
  }

  /// 核心名匹配：返回匹配结果（语言 + 分数），不匹配返回 null。
  static _MatchResult? _matchCore(
    List<String> videoCore,
    List<String> subSegs,
  ) {
    final stripped = _stripLanguage(subSegs);
    final subCore = stripped.core;
    final lang = stripped.lang;

    final episodeCompatibility = _episodeCompatibility(videoCore, subCore);
    if (episodeCompatibility == false) return null;

    final same = _listEquals(videoCore, subCore);
    final prefix = _prefixWithReleaseCheck(videoCore, subCore);
    final common = _commonPrefixLen(videoCore, subCore);
    final minLen = videoCore.length < subCore.length
        ? videoCore.length
        : subCore.length;
    // 公共前缀模糊匹配只服务于同一集的不同编号写法，例如
    // `My.Series.S01E01` ↔ `My.Series.01`。没有集数一致性证据时，
    // 仅共享片名前缀不能构成匹配。
    final fuzzyPrefix =
        episodeCompatibility == true &&
        ((_isEpisodeOnlyName(videoCore) || _isEpisodeOnlyName(subCore)) ||
            (common >= 1 && minLen > 0 && common / minLen >= 0.5));

    if (!same && !prefix && !fuzzyPrefix) return null;

    final SubtitleLanguage language;
    final int score;
    if (same && lang == null) {
      language = SubtitleLanguage.exact; // movie.mkv ↔ movie.srt
      score = 300;
    } else if (same && lang == SubtitleLanguage.chinese) {
      language = SubtitleLanguage.chinese; // movie.mkv ↔ movie.zh.srt
      score = 260;
    } else if (same) {
      language = SubtitleLanguage.other; // movie.mkv ↔ movie.en.srt
      score = 180;
    } else if (lang == SubtitleLanguage.chinese) {
      language =
          SubtitleLanguage.chinese; // My.Movie.2024.mkv ↔ My.Movie.chs.srt
      score = 230;
    } else if (lang == null) {
      // 无语言标签的相似字幕（默认字幕），如 movie.mkv ↔ movie.2024.1080p.srt
      language = SubtitleLanguage.other;
      score = 170;
    } else {
      language = SubtitleLanguage.other; // My.Movie.2024.mkv ↔ My.Movie.en.srt
      score = 150;
    }
    return _MatchResult(language, score);
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 段前缀相似：较短者是较长者的完整段前缀（严格更短），且较长者
  /// 多出的段**全部是发布信息段**（年份/分辨率/编码/来源/集数等）。
  ///
  /// 该约束防止单段短名误配无关影片（`Star.srt` → `Star.Wars.mkv`），
  /// 同时保留常见场景（`movie.mkv` ↔ `movie.2024.1080p.chs.srt`）。
  static bool _prefixWithReleaseCheck(List<String> a, List<String> b) {
    final List<String> short = a.length <= b.length ? a : b;
    final List<String> long = a.length <= b.length ? b : a;
    if (short.isEmpty || short.length >= long.length) return false;
    for (var i = 0; i < short.length; i++) {
      if (short[i] != long[i]) return false;
    }
    for (var i = short.length; i < long.length; i++) {
      if (!_isReleaseSegment(long[i])) return false;
    }
    return true;
  }

  /// 发布信息段：年份/集数/分辨率/编码/来源等可忽略的版本标记。
  static final RegExp _releaseSegmentPattern = RegExp(
    r'^(?:\d+|[0-9]{3,4}p|[0-9]+k|s\d+e\d+|e\d+|'
    r'x264|x265|h264|h265|hevc|avc|av1|'
    r'bluray|blu|ray|web|webdl|dl|webrip|rip|hdtv|dvdrip|bdrip|remux|BlueRay|'
    r'uhd|hd|hdr|hdr10|dovi|dv|atmos|truehd|dts|aac|flac|ac3|'
    r'8bit|10bit|hi10p|proper|repack|extended|uncut|multi|dual)$',
    caseSensitive: false,
  );

  /// 不属于片名的常见字幕属性后缀。
  static const Set<String> _subtitleQualifierTags = {
    'default',
    'forced',
    'force',
    'sdh',
    'cc',
    'hi',
    'full',
    'sign',
    'signs',
    'foreign',
    'commentary',
  };

  static bool _isReleaseSegment(String seg) =>
      _releaseSegmentPattern.hasMatch(seg);

  static int _commonPrefixLen(List<String> a, List<String> b) {
    var i = 0;
    while (i < a.length && i < b.length && a[i] == b[i]) {
      i++;
    }
    return i;
  }

  /// 季/集编号兼容性：false=明确冲突，true=明确同集，null=无集数证据。
  static bool? _episodeCompatibility(List<String> video, List<String> sub) {
    final videoExplicit = _explicitEpisode(video);
    final subExplicit = _explicitEpisode(sub);

    if (videoExplicit != null && subExplicit != null) {
      if (videoExplicit.episode != subExplicit.episode) return false;
      if (videoExplicit.season != null &&
          subExplicit.season != null &&
          videoExplicit.season != subExplicit.season) {
        return false;
      }
      return true;
    }

    if (videoExplicit != null || subExplicit != null) {
      final explicit = videoExplicit ?? subExplicit!;
      final other = videoExplicit == null ? video : sub;
      final otherNumber = _lastStandaloneNumber(other);
      if (otherNumber == null) return false;
      return otherNumber == explicit.episode;
    }

    final videoNumber = _lastStandaloneNumber(video);
    final subNumber = _lastStandaloneNumber(sub);
    if (videoNumber != null && subNumber != null) {
      return videoNumber == subNumber;
    }
    return null;
  }

  static _EpisodeRef? _explicitEpisode(List<String> segments) {
    final seasonEpisode = RegExp(r'^s(\d{1,3})e(\d{1,4})(?:v\d+)?$');
    final xEpisode = RegExp(r'^(\d{1,3})x(\d{1,4})$');
    final episodeOnly = RegExp(r'^(?:e|ep|episode)(\d{1,4})(?:v\d+)?$');
    final chineseEpisode = RegExp(r'^第?(\d{1,4})[集话話]$');
    final seasonOnly = RegExp(r'^s(\d{1,3})$');

    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final se = seasonEpisode.firstMatch(segment);
      if (se != null) {
        return _EpisodeRef(int.parse(se.group(2)!), int.parse(se.group(1)!));
      }
      final xe = xEpisode.firstMatch(segment);
      if (xe != null) {
        return _EpisodeRef(int.parse(xe.group(2)!), int.parse(xe.group(1)!));
      }
      final eo = episodeOnly.firstMatch(segment);
      if (eo != null) return _EpisodeRef(int.parse(eo.group(1)!));
      final ce = chineseEpisode.firstMatch(segment);
      if (ce != null) return _EpisodeRef(int.parse(ce.group(1)!));

      final so = seasonOnly.firstMatch(segment);
      if (so != null && i + 1 < segments.length) {
        final nextEpisode = episodeOnly.firstMatch(segments[i + 1]);
        if (nextEpisode != null) {
          return _EpisodeRef(
            int.parse(nextEpisode.group(1)!),
            int.parse(so.group(1)!),
          );
        }
      }
    }
    return null;
  }

  static int? _lastStandaloneNumber(List<String> segments) {
    final number = RegExp(r'^\d{1,4}$');
    for (final segment in segments.reversed) {
      if (number.hasMatch(segment)) return int.parse(segment);
    }
    return null;
  }

  /// 是否仅由一个季集编号或纯数字集号组成（`S01E01` / `E01` / `01`）。
  ///
  /// 同目录中常见字幕会直接命名为 `01.ass`；在季集编号已经确认一致时，
  /// 允许这种无片名字幕与完整视频名匹配。
  static bool _isEpisodeOnlyName(List<String> segments) {
    if (segments.length != 1) return false;
    return _explicitEpisode(segments) != null ||
        _lastStandaloneNumber(segments) != null;
  }

  static bool _isSameDirectory(String mediaHref, String subtitleHref) {
    final media = Uri.tryParse(mediaHref);
    final subtitle = Uri.tryParse(subtitleHref);
    if (media == null || subtitle == null) return false;

    if (media.hasAuthority && subtitle.hasAuthority) {
      if (media.scheme.toLowerCase() != subtitle.scheme.toLowerCase() ||
          media.host.toLowerCase() != subtitle.host.toLowerCase() ||
          media.port != subtitle.port) {
        return false;
      }
    }

    final mediaSegments = media.pathSegments;
    final subtitleSegments = subtitle.pathSegments;
    if (mediaSegments.isEmpty || subtitleSegments.isEmpty) return false;
    return _listEquals(
      mediaSegments.sublist(0, mediaSegments.length - 1),
      subtitleSegments.sublist(0, subtitleSegments.length - 1),
    );
  }
}

/// 语言剥离结果。
class _Stripped {
  const _Stripped(this.core, this.lang);

  /// 剥离语言标签后的核心名段序列。
  final List<String> core;

  /// 剥离出的语言分类；无语言标签为 null。
  final SubtitleLanguage? lang;
}

/// 匹配结果（对外映射 + 排序分数）。
class _MatchResult {
  const _MatchResult(this.language, this.score);

  final SubtitleLanguage language;
  final int score;
}

class _EpisodeRef {
  const _EpisodeRef(this.episode, [this.season]);

  final int episode;
  final int? season;
}
