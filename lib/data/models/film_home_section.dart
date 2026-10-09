import 'film_catalog_item.dart';

class FilmHomeSection {
  const FilmHomeSection(this.id, {this.enabled = false});
  final String id;
  final bool enabled;
  FilmHomeSection withEnabled(bool value) =>
      FilmHomeSection(id, enabled: value);
  Map<String, Object> toJson() => {'id': id, 'enabled': enabled};
  String get value => id.substring(id.indexOf(':') + 1);
  String get label => switch (id) {
    'continue' => '继续播放',
    'daily' => '每日精选',
    'collections' => '合集',
    'sources' => '媒体来源',
    'recent' => '最近添加',
    'movies' => '电影',
    'series' => '剧集',
    _ when id.startsWith('genre:') => '类型：{value}',
    _ when id.startsWith('country:') => '地区：{value}',
    _ => '{value} 年代',
  };
  FilmMediaType? get type => switch (id) {
    'movies' => FilmMediaType.movie,
    'series' => FilmMediaType.tv,
    _ => null,
  };
  static const defaults = [
    FilmHomeSection('continue', enabled: true),
    FilmHomeSection('daily', enabled: true),
    FilmHomeSection('collections', enabled: true),
    FilmHomeSection('sources', enabled: true),
    FilmHomeSection('recent', enabled: true),
    FilmHomeSection('movies', enabled: true),
    FilmHomeSection('series', enabled: true),
  ];
}
