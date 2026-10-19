import 'dart:convert';

/// 作品默认版本与单季覆盖；版本键不依赖界面排列。
class FilmVersionSelection {
  FilmVersionSelection({
    required this.defaultKey,
    Map<int, String> seasons = const {},
  }) : seasons = Map.unmodifiable(seasons);
  final String defaultKey;
  final Map<int, String> seasons;
  String forSeason(int season) => seasons[season] ?? defaultKey;
  FilmVersionSelection withSeason(int season, String key) =>
      FilmVersionSelection(
        defaultKey: defaultKey,
        seasons: {...seasons, season: key},
      );
  Map<String, dynamic> toJson() => {
    'default': defaultKey,
    'seasons': {for (final e in seasons.entries) '${e.key}': e.value},
  };
  factory FilmVersionSelection.fromJson(Map<String, dynamic> json) =>
      FilmVersionSelection(
        defaultKey: json['default'] as String,
        seasons: {
          for (final e in (json['seasons'] as Map).entries)
            int.parse(e.key as String): e.value as String,
        },
      );
}

/// 一次起播固定选择，恢复会话时不读取后续修改的偏好。
class FilmPlaybackContext {
  const FilmPlaybackContext({
    required this.workId,
    required this.identity,
    required this.selection,
    this.sourceScope,
  });
  final int workId;
  final String identity;
  final String? sourceScope;
  final FilmVersionSelection selection;
  String get signature {
    final keys = selection.seasons.keys.toList()..sort();
    return jsonEncode([
      identity,
      sourceScope,
      selection.defaultKey,
      for (final k in keys) [k, selection.seasons[k]],
    ]);
  }

  Map<String, dynamic> toJson() => {
    'workId': workId,
    'identity': identity,
    'sourceScope': sourceScope,
    'selection': selection.toJson(),
  };
  factory FilmPlaybackContext.fromJson(Map<String, dynamic> json) =>
      FilmPlaybackContext(
        workId: json['workId'] as int,
        identity: json['identity'] as String,
        sourceScope: json['sourceScope'] as String?,
        selection: FilmVersionSelection.fromJson(
          json['selection'] as Map<String, dynamic>,
        ),
      );
}
