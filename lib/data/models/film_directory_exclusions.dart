class FilmDirectoryExclusions {
  const FilmDirectoryExclusions({this.names = const [], this.exact = false});

  factory FilmDirectoryExclusions.fromJson(Map<String, dynamic> json) =>
      FilmDirectoryExclusions(
        names: (json['names'] as List).cast<String>(),
        exact: json['exact'] as bool,
      );

  final List<String> names;
  final bool exact;

  static List<String> parseNames(String text) => text
      .split(',')
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toSet()
      .toList();

  bool excludesName(String name) =>
      names.any((keyword) => exact ? name == keyword : name.contains(keyword));

  bool excludesPath(String directory) => directory.split('/').any(excludesName);

  Map<String, Object> toJson() => {'names': names, 'exact': exact};
}
