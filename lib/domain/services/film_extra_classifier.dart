import '../../data/models/film_extra.dart';

/// 仅检查已有名称，不读取文件、目录或网络。
class FilmExtraClassifier {
  FilmExtraClassifier(this.rules) {
    for (final type in rules.types) {
      for (final alias in type.aliases) {
        final normalized = normalize(alias).trim();
        if (normalized.isEmpty) continue;
        final words = normalized
            .split(RegExp(r'[ ._\-]+'))
            .map(RegExp.escape)
            .join(r'[ ._\-]*');
        final cjk =
            RegExp(r'[\u3400-\u9fff\u3040-\u30ff]').hasMatch(normalized) &&
            type.id != 'ncop' &&
            type.id != 'nced';
        final boundary = cjk ? r'a-z0-9\u3400-\u9fff\u3040-\u30ff' : 'a-z0-9';
        _patterns.add((
          type.id,
          alias,
          RegExp(
            '(?<![$boundary])$words(?![${cjk ? r'a-z\u3400-\u9fff\u3040-\u30ff' : 'a-z'}])',
          ),
        ));
      }
    }
  }
  final FilmExtraRules rules;
  final _patterns = <(String, String, RegExp)>[];

  static String normalize(String value) => String.fromCharCodes(
    value.runes.map(
      (r) => r >= 0xff01 && r <= 0xff5e
          ? r - 0xfee0
          : r == 0x3000
          ? 32
          : r,
    ),
  ).toLowerCase();

  static bool excludedDirectory(String value) =>
      RegExp(r'^(?:scans?|cds?)$').hasMatch(
        normalize(
          value,
        ).replaceAll(RegExp(r'^[\s《》\[\](){}「」『』]+|[\s《》\[\](){}「」『』]+$'), ''),
      );
  static bool excludedPath(String path) =>
      path.replaceAll('\\', '/').split('/').any(excludedDirectory);

  static void validateRules(List<FilmExtraType> types) {
    final ids = <String>{};
    final aliases = <String, String>{};
    final generic = FilmExtraRules.genericAliases.map(normalize).toSet();
    for (final type in types) {
      if (!ids.add(type.id) || type.id.isEmpty || type.label.trim().isEmpty) {
        throw const FormatException('invalidExtraType');
      }
      if (type.aliases.isEmpty && type.id != 'mixed') {
        throw const FormatException('emptyExtraAlias');
      }
      for (final alias in type.aliases) {
        final key = normalize(
          alias,
        ).trim().replaceAll(RegExp(r'[ ._\-]+'), ' ');
        if (key.isEmpty) throw const FormatException('emptyExtraAlias');
        if ((generic.contains(normalize(alias).trim()) && type.id != 'other') ||
            aliases.containsKey(key) && aliases[key] != type.id) {
          throw const FormatException('duplicateExtraAlias');
        }
        aliases[key] = type.id;
      }
    }
    if (!FilmExtraRules.defaults.every((t) => ids.contains(t.id))) {
      throw const FormatException('invalidExtraType');
    }
  }

  FilmExtraClassification _name(String name, String origin) {
    final value = normalize(name);
    final hits = <(String, String, int, int)>[];
    for (final (kind, alias, pattern) in _patterns) {
      for (final m in pattern.allMatches(value)) {
        hits.add((kind, alias, m.start, m.end));
      }
    }
    // 较长的复合别名优先，例如“下集预告”不再同时命中“预告”。
    hits.removeWhere(
      (h) => hits.any(
        (other) =>
            other.$3 <= h.$3 &&
            other.$4 >= h.$4 &&
            other.$4 - other.$3 > h.$4 - h.$3,
      ),
    );
    final specific = hits.where((h) => h.$1 != 'other').toList();
    if (specific.isNotEmpty) {
      final kinds = specific.map((h) => h.$1).toSet().toList()..sort();
      return FilmExtraClassification(
        kind: kinds.length == 1 ? kinds.single : 'mixed',
        origin: origin,
        status: 'extra',
        keywords: specific.map((h) => h.$2).toSet().toList(),
        kinds: kinds,
      );
    }
    if (hits.isNotEmpty) {
      return FilmExtraClassification(
        kind: 'other',
        origin: origin,
        status: 'extra',
        keywords: hits.map((h) => h.$2).toSet().toList(),
      );
    }
    return const FilmExtraClassification();
  }

  FilmExtraClassification classify({
    required String name,
    required String path,
    required String rootPath,
    String? workDirectory,
    String mediaKind = 'video',
  }) {
    if (path.contains('://') ||
        path.contains('\\') ||
        path.split('/').any((s) => s == '.' || s == '..')) {
      return const FilmExtraClassification();
    }
    if (mediaKind != 'video' && mediaKind != 'strm') {
      return const FilmExtraClassification();
    }
    if (excludedPath(
      path.substring(0, path.lastIndexOf('/') < 0 ? 0 : path.lastIndexOf('/')),
    )) {
      return const FilmExtraClassification();
    }
    final root = rootPath.isEmpty ? '' : '$rootPath/';
    if (!path.startsWith(root)) return const FilmExtraClassification();
    final inside = path.substring(root.length).split('/');
    final filename = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    var recognitionName = filename;
    // 年份作品容器中的完整片名不是特典标记，例如《死亡笔记特别篇》。
    if (inside.length > 1) {
      final container = RegExp(
        r'^\d{4}\s*[-–—]\s*《(.+)》$',
      ).firstMatch(inside.first);
      final title = container?[1];
      if (title != null && normalize(filename).startsWith(normalize(title))) {
        recognitionName = filename.substring(title.length);
      }
    }
    final own = _name(recognitionName, 'filename');
    // 根下第一层视为作品容器，不把作品名称应用为目录分类。
    final folders = inside.length > 2
        ? inside.sublist(1, inside.length - 1)
        : <String>[];
    if (workDirectory != null &&
        (workDirectory == rootPath || workDirectory.startsWith(root)) &&
        path.startsWith('$workDirectory/')) {
      folders.clear();
      folders.addAll(
        path.substring(workDirectory.length + 1).split('/')..removeLast(),
      );
    }
    if (own.isExtra && own.kind != 'other') {
      for (final folder in folders.reversed) {
        if (_name(folder, 'folder').isExtra) {
          return own.inDirectory(
            path.substring(
              0,
              path.lastIndexOf('/$folder/') + folder.length + 1,
            ),
          );
        }
      }
      return own;
    }
    FilmExtraClassification? generic = own.isExtra ? own : null;
    for (final folder in folders.reversed) {
      final directory = path.substring(
        0,
        path.lastIndexOf('/$folder/') + folder.length + 1,
      );
      // 这是容器的混合标记，文件名中的明确类型已优先处理。
      if (RegExp(
        r'(?<![a-z])ncop\s*[&+]\s*(?:nc)?ed(?![a-z])',
      ).hasMatch(normalize(folder))) {
        return const FilmExtraClassification(
          kind: 'mixed',
          origin: 'folder',
          status: 'extra',
          keywords: ['NCOP&ED'],
          kinds: ['ncop', 'nced'],
        ).inDirectory(directory);
      }
      final result = _name(folder, 'folder').inDirectory(directory);
      if (result.isExtra && result.kind != 'other') return result;
      if (result.isExtra) generic ??= result;
    }
    if (generic != null) return generic;
    if (RegExp(
      r'(?<![a-z0-9])s0+e\d+(?![a-z0-9])',
      caseSensitive: false,
    ).hasMatch(filename)) {
      return const FilmExtraClassification(
        kind: 'other',
        origin: 'filename',
        status: 'extra',
        keywords: ['S00'],
      );
    }
    return const FilmExtraClassification();
  }
}
