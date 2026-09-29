import 'dart:async';
import 'dart:io';

import '../../core/errors/app_exception.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';
import '../repositories/media_directory_source.dart';
import 'special_video_playlist_collector.dart';

class SeasonDirectoryCandidate {
  const SeasonDirectoryCandidate({
    required this.path,
    required this.season,
    required this.entries,
  });

  final String path;
  final int season;
  final List<MediaDirectoryEntry> entries;
}

/// 只读取当前视频目录的父目录，以及有限个可能属于同一作品的同级目录。
class SeasonVideoPlaylistCollector {
  const SeasonVideoPlaylistCollector();

  static const maxCandidateDirectories = 8;
  static const maxVideoNamesPerDirectory = 64;
  static const lookupTimeout = Duration(seconds: 8);

  static final _seasonInFile = RegExp(
    r'(?<![a-z0-9])(?:s(?:eason)?[ ._-]*|season[ ._-]*)(0*[1-9]\d?)(?=e\d|[^a-z0-9]|$)',
    caseSensitive: false,
  );
  static final _chineseSeason = RegExp(r'第([一二三四五六七八九十两\d]{1,3})季');
  static final _folderOrdinal = RegExp(r'^(0*[1-9]\d?)(?=$|[.、_ -])');
  static final _folderEnglish = RegExp(
    r'^(?:s|season[ ._-]*)(0*[1-9]\d?)(?=$|[^a-z0-9])',
    caseSensitive: false,
  );

  static String _normalize(String value) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      buffer.writeCharCode(
        rune >= 0xff01 && rune <= 0xff5e ? rune - 0xfee0 : rune,
      );
    }
    return buffer.toString().toLowerCase();
  }

  static int? _chineseNumber(String value) {
    final decimal = int.tryParse(value);
    if (decimal != null) return decimal;
    const digits = {
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
      '两': 2,
    };
    if (value == '十') return 10;
    final ten = value.indexOf('十');
    if (ten >= 0) {
      final high = ten == 0 ? 1 : digits[value.substring(0, ten)];
      final low = ten == value.length - 1
          ? 0
          : digits[value.substring(ten + 1)];
      return high == null || low == null ? null : high * 10 + low;
    }
    return digits[value];
  }

  static int? seasonFromFolder(String name) {
    final value = _normalize(name).trim();
    if (SpecialVideoPlaylistCollector.isSpecialName(value)) return null;
    final ordinal = _folderOrdinal.firstMatch(value);
    if (ordinal != null) return int.tryParse(ordinal.group(1)!);
    final english = _folderEnglish.firstMatch(value);
    if (english != null) return int.tryParse(english.group(1)!);
    final chinese = _chineseSeason.firstMatch(value);
    return chinese == null ? null : _chineseNumber(chinese.group(1)!);
  }

  static int? seasonFromVideo(String name) {
    final value = _normalize(name);
    final english = _seasonInFile.firstMatch(value);
    if (english != null) return int.tryParse(english.group(1)!);
    final chinese = _chineseSeason.firstMatch(value);
    return chinese == null ? null : _chineseNumber(chinese.group(1)!);
  }

  static String _title(String name, {required bool video}) {
    var value = _normalize(name);
    if (video) {
      final marker = _seasonInFile.firstMatch(value);
      if (marker != null) value = value.substring(0, marker.start);
      value = value.replaceFirst(RegExp(r'\.[a-z0-9]{2,5}$'), '');
    } else {
      value = value.replaceFirst(_folderOrdinal, '');
      value = value.replaceFirst(_folderEnglish, '');
      value = value.replaceFirst(_chineseSeason, '');
    }
    value = value.replaceAll(RegExp(r'(?:19|20)\d{2}'), '');
    return value.replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), '');
  }

  static bool _usefulTitle(String value) =>
      value.length >= 3 ||
      (value.length >= 2 && RegExp(r'[\u4e00-\u9fff]').hasMatch(value));

  static bool _related(String left, String right) =>
      _usefulTitle(left) &&
      _usefulTitle(right) &&
      (left == right || left.startsWith(right) || right.startsWith(left));

  static List<MediaDirectoryEntry> _videos(List<MediaDirectoryEntry> entries) =>
      entries
          .where(
            (entry) =>
                !entry.isDirectory &&
                (entry.isVideo ||
                    (entry.sourceKind == MediaSourceKind.webdav &&
                        entry.isStrm)),
          )
          .take(maxVideoNamesPerDirectory)
          .toList(growable: false);

  static int? _videoSeason(List<MediaDirectoryEntry> entries) {
    final seasons = _videos(
      entries,
    ).map((entry) => seasonFromVideo(entry.name)).whereType<int>().toSet();
    return seasons.length == 1 ? seasons.single : null;
  }

  Future<SeasonDirectoryCandidate?> findNext({
    required MediaDirectorySource source,
    required String rootPath,
    required List<MediaDirectoryEntry> rootEntries,
    required bool allowGap,
  }) async {
    if (rootPath.isEmpty ||
        rootPath.split('/').any((part) => part.toLowerCase() == 'bdmv') ||
        SpecialVideoPlaylistCollector.isSpecialName(rootPath.split('/').last)) {
      return null;
    }
    final rootName = rootPath.split('/').last;
    final folderSeason = seasonFromFolder(rootName);
    final videoSeason = _videoSeason(rootEntries);
    if (folderSeason != null &&
        videoSeason != null &&
        folderSeason != videoSeason) {
      return null;
    }
    final currentSeason = videoSeason ?? folderSeason;
    if (currentSeason == null || _videos(rootEntries).isEmpty) return null;
    final rootVideoTitle = _videos(rootEntries)
        .where((item) => seasonFromVideo(item.name) == currentSeason)
        .map((item) => _title(item.name, video: true))
        .where(_usefulTitle)
        .firstOrNull;
    final rootTitle = rootVideoTitle ?? _title(rootName, video: false);
    final slash = rootPath.lastIndexOf('/');
    final parentPath = slash < 0 ? '' : rootPath.substring(0, slash);
    final deadline = DateTime.now().add(lookupTimeout);
    List<MediaDirectoryEntry> siblings;
    try {
      siblings = await source.fetchDirectory(parentPath).timeout(lookupTimeout);
    } on AppException {
      return null;
    } on FileSystemException {
      return null;
    } on TimeoutException {
      return null;
    }
    final paths =
        <
          ({String path, int? season, bool related, MediaDirectoryEntry entry})
        >[];
    for (final entry in siblings) {
      if (!entry.isDirectory ||
          SpecialVideoPlaylistCollector.isSpecialName(entry.name)) {
        continue;
      }
      final path = SpecialVideoPlaylistCollector.directChildPath(
        source,
        parentPath,
        entry,
      );
      if (path == null || path == rootPath) continue;
      final number = seasonFromFolder(entry.name);
      final titleRelated = _related(
        rootTitle,
        _title(entry.name, video: false),
      );
      if (number != null &&
          (number <= currentSeason ||
              (!allowGap && number != currentSeason + 1))) {
        continue;
      }
      if (number == null && !titleRelated) {
        continue;
      }
      paths.add((
        path: path,
        season: number,
        related: titleRelated,
        entry: entry,
      ));
    }
    paths.sort((a, b) {
      final number = (a.season ?? 100).compareTo(b.season ?? 100);
      return number != 0 ? number : (b.related ? 1 : 0) - (a.related ? 1 : 0);
    });
    final matched = <SeasonDirectoryCandidate>[];
    for (final candidate in paths.take(maxCandidateDirectories)) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      List<MediaDirectoryEntry> entries;
      try {
        await source.resolve(candidate.entry).timeout(remaining);
        final fetchRemaining = deadline.difference(DateTime.now());
        if (fetchRemaining <= Duration.zero) break;
        entries = await source
            .fetchDirectory(candidate.path)
            .timeout(fetchRemaining);
      } on AppException {
        continue;
      } on FileSystemException {
        continue;
      } on TimeoutException {
        break;
      }
      final season = _videoSeason(entries);
      if (season == null ||
          season <= currentSeason ||
          (!allowGap && season != currentSeason + 1) ||
          (candidate.season != null && candidate.season != season)) {
        continue;
      }
      final videoTitle = _videos(entries)
          .where((item) => seasonFromVideo(item.name) == season)
          .map((item) => _title(item.name, video: true))
          .where(_usefulTitle)
          .firstOrNull;
      final folderTitle = _title(candidate.entry.name, video: false);
      if (!_related(rootTitle, videoTitle ?? folderTitle)) continue;
      matched.add(
        SeasonDirectoryCandidate(
          path: candidate.path,
          season: season,
          entries: entries,
        ),
      );
    }
    if (matched.isEmpty) return null;
    matched.sort((a, b) => a.season.compareTo(b.season));
    if (matched.length > 1 && matched[0].season == matched[1].season) {
      return null;
    }
    return matched.first;
  }
}
