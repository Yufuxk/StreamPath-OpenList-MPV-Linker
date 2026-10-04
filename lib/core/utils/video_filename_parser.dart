/// 文件名中的显示与匹配信息，不改变播放地址或排序。
class VideoFilenameInfo {
  const VideoFilenameInfo({
    required this.title,
    required this.score,
    this.year,
    this.season,
    this.episodes,
    this.date,
    this.special,
    this.description = '',
  });

  final String title;
  final int score;
  final int? year;
  final int? season;
  final String? episodes;
  final String? date;
  final String? special;
  final String description;
}

/// 根据明确标记及上下文评分；信息不足或候选冲突时保留原文件名。
class VideoFilenameParser {
  const VideoFilenameParser();

  static const minimumScore = 70;
  static final _extension = RegExp(
    r'\.(?:mkv|mp4|avi|mov|wmv|flv|webm|m4v|mpg|mpeg|ts|m2ts|mts|vob|ogm|rmvb|rm|strm)$',
    caseSensitive: false,
  );
  static final _year = RegExp(r'(?<!\d)((?:19|20)\d{2})(?!\d)');
  static final _technical = RegExp(
    r'(?<![a-z0-9])(?:blu[ ._-]?ray|blue[ ._-]?ray|bd[ ._-]?remux|remux|bdrip|brrip|bd|uhd|web[ ._-]?(?:dl|rip)|hdtv|dvdrip|dvd|cam|telesync|(?:480|576|720|1080|1440|2160|4320)[pi]|[248]k|\d{3,4}x\d{3,4}|[hx][ ._-]?26[45]|avc|hevc|av1|xvid|divx|flac|aac|ac3|eac3|ddp|truehd|dts(?:[ ._-]?hd)?|pcm|lpcm|hdr10\+?|hdr|dovi|dolby[ ._-]?vision|hi10p|10bit|8bit)(?![a-z0-9])',
    caseSensitive: false,
  );
  static const _number = r'(?:\d{1,4}|[零〇一二三四五六七八九十百两兩]{1,5})';
  static final _seasonEpisode = RegExp(
    r'(?<![a-z0-9])s(\d{1,2})[ ._-]*x?e[ ._-]*(\d{1,4})((?:[ ._-]*e[ ._-]*\d{1,4}|-(?:s\d{1,2}[ ._-]*)?e?[ ._-]*\d{1,4})*)(?![a-z0-9])',
    caseSensitive: false,
  );
  static final _crossEpisode = RegExp(
    r'(?<![a-z0-9])(\d{1,2})x(\d{1,4})((?:x\d{1,4}|-(?:\d{1,2}x)?\d{1,4})*)(?![a-z0-9])',
    caseSensitive: false,
  );
  static final _namedSeasonEpisode = RegExp(
    r'(?<![a-z0-9])season[ ._-]*(\d{1,2})[ ._-]+(?:episode|ep)[ ._-]*(\d{1,4})(?![a-z0-9])',
    caseSensitive: false,
  );
  static final _chineseSeasonEpisode = RegExp(
    '第($_number)季[ ._-]*第?($_number)[集话話回]',
  );
  static final _chineseEpisode = RegExp('第($_number)[集话話回]');
  static final _episode = RegExp(
    r'(?<![a-z0-9])(?:episode|ep|e)[ ._-]*(\d{1,4})(?:v\d+)?((?:-(?:ep?)?\d{1,4})*)(?![a-z0-9])',
    caseSensitive: false,
  );
  static final _animeEpisode = RegExp(
    r'(?:[ ._]+-[ ._]+|\[)(\d{1,4})(?:v\d+)?(?:-(\d{1,4}))?(?:\]|(?=$|[ ._\[(]))',
    caseSensitive: false,
  );
  static final _season = RegExp(
    r'(?<![a-z0-9])(?:s|season[ ._-]*)(\d{1,2})(?![a-z0-9])',
    caseSensitive: false,
  );
  static final _chineseSeason = RegExp('第($_number)季');
  static final _special = RegExp(
    r'(?<![a-z0-9])(?:specials?|ova|oav|oad|ona|sp|ncop|nced|op|ed|pv)(?:[ ._-]*(\d{1,3}))?(?![a-z0-9])|特别篇|特別篇|番外篇?',
    caseSensitive: false,
  );
  static final _date = RegExp(
    r'(?<!\d)((?:19|20)\d{2})[ ._-](\d{2})[ ._-](\d{2})(?!\d)',
  );
  static final _dayFirstDate = RegExp(
    r'(?<!\d)(\d{2})[ ._-](\d{2})[ ._-]((?:19|20)\d{2})(?!\d)',
  );
  static final _bareEpisode = RegExp(r'[._](\d{2,3})(?=[ ._\[(]|$)');
  static final _identitySuffix = RegExp(
    r"(?<![a-z0-9])(?:director'?s[ ._-]+cut|extended(?:[ ._-]+cut)?|unrated|uncut|theatrical(?:[ ._-]+cut)?|remastered|imax|final[ ._-]+cut|(?:part|pt|cd|disc)[ ._-]*\d{1,2})(?![a-z0-9])",
    caseSensitive: false,
  );
  static final _releaseFlags = RegExp(
    r'(?<![a-z0-9])(?:proper|repack|rerip)(?![a-z0-9])',
    caseSensitive: false,
  );

  VideoFilenameInfo? parse(String filename, {bool movie = false}) {
    final value = filename.replaceFirst(_extension, '');
    final technical = _technical.firstMatch(value);
    final content = technical == null
        ? value
        : value.substring(0, technical.start);
    final candidates = <VideoFilenameInfo>[];
    final years = _year
        .allMatches(content)
        .where((match) => match.start > 0)
        .toList();
    final year = years.isEmpty ? null : int.parse(years.last[1]!);
    String descriptionAfter(int offset) {
      var description = _clean(
        content.substring(offset).replaceAll(_releaseFlags, ''),
      );
      for (final match in _identitySuffix.allMatches(value.substring(offset))) {
        final label = _clean(match[0]!);
        if (!description.toLowerCase().contains(label.toLowerCase())) {
          description = '$description $label'.trim();
        }
      }
      return description;
    }

    void add(
      RegExpMatch match,
      int base, {
      int? season,
      String? episodes,
      String? date,
      String? special,
    }) {
      var prefix = content.substring(0, match.start);
      int? titleYear;
      final prefixYears = _year.allMatches(prefix).toList();
      if (prefixYears.isNotEmpty) {
        final last = prefixYears.last;
        // 年份须位于片名末尾，避免移除《2001 太空漫游》中的数字。
        if (_clean(prefix.substring(last.end)).isEmpty &&
            _clean(prefix.substring(0, last.start)).isNotEmpty) {
          titleYear = int.parse(last[1]!);
          prefix = prefix.substring(0, last.start);
        }
      }
      prefix = _removeReleaseGroups(prefix);
      final title = _clean(prefix);
      if (title.isEmpty) return;
      final score =
          (base +
                  10 +
                  (titleYear == null ? 0 : 10) +
                  (technical == null ? 0 : 10))
              .clamp(0, 100);
      final description = descriptionAfter(match.end);
      candidates.add(
        VideoFilenameInfo(
          title: title,
          score: score,
          year: titleYear,
          season: season,
          episodes: episodes,
          date: date,
          special: special,
          description: description,
        ),
      );
    }

    if (!movie) {
      for (final match in _seasonEpisode.allMatches(content)) {
        final tail = match[3]!;
        final repeatedSeasons = RegExp(
          r's(\d+)',
          caseSensitive: false,
        ).allMatches(tail);
        if (repeatedSeasons.any(
          (item) => int.parse(item[1]!) != int.parse(match[1]!),
        )) {
          return null;
        }
        add(
          match,
          90,
          season: int.parse(match[1]!),
          episodes: _episodes(match[2]!, tail),
        );
      }
      for (final match in _crossEpisode.allMatches(content)) {
        final repeatedSeasons = RegExp(r'(\d+)x').allMatches(match[3]!);
        if (repeatedSeasons.any(
          (item) => int.parse(item[1]!) != int.parse(match[1]!),
        )) {
          return null;
        }
        add(
          match,
          80,
          season: int.parse(match[1]!),
          episodes: _episodes(match[2]!, match[3]!),
        );
      }
      for (final match in _namedSeasonEpisode.allMatches(content)) {
        add(
          match,
          85,
          season: int.parse(match[1]!),
          episodes: '${int.parse(match[2]!)}',
        );
      }
      for (final match in _chineseSeasonEpisode.allMatches(content)) {
        add(
          match,
          85,
          season: number(match[1]!),
          episodes: '${number(match[2]!)}',
        );
      }
      for (final match in _episode.allMatches(content)) {
        add(match, 70, episodes: _episodes(match[1]!, match[2]!));
      }
      for (final match in _chineseEpisode.allMatches(content)) {
        add(match, 70, episodes: '${number(match[1]!)}');
      }
      for (final match in _animeEpisode.allMatches(content)) {
        final first = int.parse(match[1]!);
        if (first >= 1900 ||
            const [480, 576, 720, 1080, 1440, 2160, 4320].contains(first)) {
          continue;
        }
        add(
          match,
          60,
          episodes: match[2] == null
              ? '$first'
              : '$first–${int.parse(match[2]!)}',
        );
      }
      for (final match in _date.allMatches(content)) {
        final year = int.parse(match[1]!);
        final month = int.parse(match[2]!);
        final day = int.parse(match[3]!);
        final date = DateTime(year, month, day);
        if (date.month != month || date.day != day) continue;
        add(match, 80, date: '${match[1]}-${match[2]}-${match[3]}');
      }
      for (final match in _dayFirstDate.allMatches(content)) {
        final year = int.parse(match[3]!);
        final month = int.parse(match[2]!);
        final day = int.parse(match[1]!);
        final date = DateTime(year, month, day);
        if (date.month != month || date.day != day) continue;
        add(match, 80, date: '${match[3]}-${match[2]}-${match[1]}');
      }
      for (final match in _bareEpisode.allMatches(content)) {
        if (technical == null ||
            _date.hasMatch(content) ||
            _dayFirstDate.hasMatch(content) ||
            _seasonEpisode.hasMatch(content) ||
            _crossEpisode.hasMatch(content) ||
            _episode.hasMatch(content)) {
          continue;
        }
        final episode = int.parse(match[1]!);
        if (episode == 480 || episode == 576 || episode == 720) continue;
        add(match, 50, episodes: '$episode');
      }
      for (final match in _season.allMatches(content)) {
        add(match, 65, season: int.parse(match[1]!));
      }
      for (final match in _chineseSeason.allMatches(content)) {
        add(match, 65, season: number(match[1]!));
      }
      for (final match in _special.allMatches(content)) {
        final kind = match[0]!
            .replaceAll(RegExp(r'[ ._\-\d]+'), '')
            .toUpperCase();
        add(
          match,
          65,
          season: 0,
          episodes: match[1] == null ? null : '${int.parse(match[1]!)}',
          special:
              const [
                'OVA',
                'OAV',
                'OAD',
                'ONA',
                'SP',
                'NCOP',
                'NCED',
                'OP',
                'ED',
                'PV',
              ].contains(kind)
              ? kind
              : null,
        );
      }
    }
    // 年份或技术参数只能作为较低优先级的电影命名候选。
    if (year != null) {
      final match = years.last;
      final recognizedSuffix = _clean(
        content
            .substring(match.end)
            .replaceAll(_identitySuffix, '')
            .replaceAll(_releaseFlags, ''),
      ).isEmpty;
      final title = _clean(
        _removeReleaseGroups(content.substring(0, match.start)),
      );
      if (title.isNotEmpty && (recognizedSuffix || technical != null)) {
        candidates.add(
          VideoFilenameInfo(
            title: title,
            year: year,
            score: !recognizedSuffix ? 60 : (technical == null ? 70 : 80),
            description: descriptionAfter(match.end),
          ),
        );
      }
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    if (candidates.isEmpty || candidates.first.score < minimumScore) {
      return null;
    }
    final best = candidates.first;
    // 两组明确的季集标记不能靠先后顺序猜测。
    if (candidates
        .skip(1)
        .any(
          (other) =>
              other.score >= best.score - 5 &&
              ((other.season != null &&
                      best.season != null &&
                      other.season != best.season) ||
                  (other.episodes != null &&
                      best.episodes != null &&
                      other.episodes != best.episodes) ||
                  (other.date != null &&
                      best.date != null &&
                      other.date != best.date)),
        )) {
      return null;
    }
    return best;
  }

  static String _episodes(String first, String tail) {
    final numbers = RegExp(r'(?:e|x)?(\d+)', caseSensitive: false)
        .allMatches(
          tail
              .replaceAll(RegExp(r's\d+', caseSensitive: false), '')
              .replaceAll(RegExp(r'\d+x'), ''),
        )
        .map((match) => int.parse(match[1]!))
        .toList();
    return [
      int.parse(first),
      ...numbers,
    ].join(tail.contains('-') && numbers.length == 1 ? '–' : ', ');
  }

  static String _removeReleaseGroups(String value) {
    final stripped = value.replaceFirst(RegExp(r'^(?:\[[^\]]+\][ ._]*)+'), '');
    return _clean(stripped).isEmpty ? value : stripped;
  }

  static String _clean(String value) => value
      .replaceAll(
        RegExp(
          r'\{(?:tmdb|tvdb|imdb)[^}]*\}|\[(?:tmdb|tvdb|imdb)[^\]]*\]',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\[[0-9a-fA-F]{8}\]'), '')
      .replaceAll(RegExp(r'[._]+'), ' ')
      .replaceAll(RegExp(r'^[\s\-\[\]()]+|[\s\-\[\]()]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static int number(String value) {
    final decimal = int.tryParse(value);
    if (decimal != null) return decimal;
    const digits = {
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '兩': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    var total = 0;
    var current = 0;
    for (final char in value.split('')) {
      if (char == '十' || char == '百') {
        total += (current == 0 ? 1 : current) * (char == '十' ? 10 : 100);
        current = 0;
      } else {
        current = digits[char]!;
      }
    }
    return total + current;
  }

  static String chineseOrdinal(int value) {
    const digits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
    if (value < 10) return digits[value];
    if (value < 100) {
      return '${value < 20 ? '' : digits[value ~/ 10]}十${value % 10 == 0 ? '' : digits[value % 10]}';
    }
    return '$value';
  }
}
