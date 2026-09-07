import '../../data/models/media_directory_entry.dart';
import '../../data/models/web_dav_file.dart';

/// 文件浏览页支持的排序方式。
enum FileSortMode { name, modified, size }

/// 文件浏览页支持的排序顺序。
enum FileSortDirection { ascending, descending }

extension FileSortModeLabel on FileSortMode {
  String get jsonValue => switch (this) {
    FileSortMode.name => 'name',
    FileSortMode.modified => 'modified',
    FileSortMode.size => 'size',
  };

  String get label => switch (this) {
    FileSortMode.name => '按名称',
    FileSortMode.modified => '按时间',
    FileSortMode.size => '按体积',
  };
}

extension FileSortDirectionLabel on FileSortDirection {
  String get jsonValue => switch (this) {
    FileSortDirection.ascending => 'ascending',
    FileSortDirection.descending => 'descending',
  };

  String get label => switch (this) {
    FileSortDirection.ascending => '正序',
    FileSortDirection.descending => '倒序',
  };
}

/// 从配置值读取排序方式。兼容手工配置时常见的英文及中文别名。
FileSortMode fileSortModeFromJson(Object? value) {
  final normalized = value?.toString().trim().toLowerCase();
  return switch (normalized) {
    'modified' || 'time' || 'date' || '按时间' || '时间' => FileSortMode.modified,
    'size' || '按体积' || '体积' || '大小' => FileSortMode.size,
    _ => FileSortMode.name,
  };
}

/// 从配置值读取排序顺序，旧配置及未知值默认使用正序。
FileSortDirection fileSortDirectionFromJson(Object? value) {
  final normalized = value?.toString().trim().toLowerCase();
  return switch (normalized) {
    'descending' || 'desc' || 'reverse' || '倒序' => FileSortDirection.descending,
    _ => FileSortDirection.ascending,
  };
}

/// 当前可见条目中是否存在可按体积排序的普通文件。
bool canSortWebDavFilesBySize(Iterable<WebDavFile> files) {
  return canSortMediaEntriesBySize(files);
}

bool canSortMediaEntriesBySize(Iterable<MediaDirectoryEntry> files) =>
    files.any((file) => !file.isDirectory && !file.isSelfEntry);

/// 返回一个排序后的新列表，不修改 WebDAV 缓存或播放列表持有的原列表。
List<WebDavFile> sortedWebDavFiles(
  Iterable<WebDavFile> files, {
  FileSortMode mode = FileSortMode.name,
  FileSortDirection direction = FileSortDirection.ascending,
}) {
  final result = files.toList();
  result.sort(
    (a, b) => compareWebDavFiles(a, b, mode: mode, direction: direction),
  );
  return result;
}

List<T> sortedMediaEntries<T extends MediaDirectoryEntry>(
  Iterable<T> files, {
  FileSortMode mode = FileSortMode.name,
  FileSortDirection direction = FileSortDirection.ascending,
}) {
  final result = files.toList();
  result.sort(
    (a, b) => compareMediaEntries(a, b, mode: mode, direction: direction),
  );
  return result;
}

/// 固定分组为“返回上级 -> 目录 -> 文件”，仅改变组内排序方式。
int compareWebDavFiles(
  WebDavFile a,
  WebDavFile b, {
  FileSortMode mode = FileSortMode.name,
  FileSortDirection direction = FileSortDirection.ascending,
}) => compareMediaEntries(a, b, mode: mode, direction: direction);

int compareMediaEntries(
  MediaDirectoryEntry a,
  MediaDirectoryEntry b, {
  FileSortMode mode = FileSortMode.name,
  FileSortDirection direction = FileSortDirection.ascending,
}) {
  if (a.isSelfEntry != b.isSelfEntry) return a.isSelfEntry ? -1 : 1;
  if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;

  // 网络目录没有可靠的总体积；体积模式下目录固定回退正序自然名称。
  if (mode == FileSortMode.size && a.isDirectory) {
    final byDirectoryName = naturalCompare(a.name, b.name);
    if (byDirectoryName != 0) return byDirectoryName;
    return a.entryKey.compareTo(b.entryKey);
  }

  if (mode == FileSortMode.modified &&
      (a.modified == null || b.modified == null)) {
    if (a.modified != b.modified) return a.modified == null ? 1 : -1;
  }

  final ascendingPrimary = switch (mode) {
    FileSortMode.name => naturalCompare(a.name, b.name),
    FileSortMode.modified => _compareModifiedByMinute(a.modified, b.modified),
    FileSortMode.size => a.size.compareTo(b.size),
  };
  final primary = _withDirection(ascendingPrimary, direction);
  if (primary != 0) return primary;

  final byName = _withDirection(naturalCompare(a.name, b.name), direction);
  if (byName != 0) return byName;
  return _withDirection(a.entryKey.compareTo(b.entryKey), direction);
}

int _withDirection(int value, FileSortDirection direction) {
  return direction == FileSortDirection.ascending ? value : -value;
}

int _compareModifiedByMinute(DateTime? a, DateTime? b) {
  if (a == null || b == null) return 0;
  final leftMinute = a.millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute;
  final rightMinute =
      b.millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute;
  return leftMinute.compareTo(rightMinute);
}

/// 不依赖平台区域设置的自然名称比较器。
///
/// 数字块按数值语义比较且不转成固定宽度整数，因而兼容任意长度编号；
/// 同时归一化全角字符，并把“第十二集”等常见中文序数转成数字后比较。
int naturalCompare(String a, String b) {
  final explicitNumberCompared = _compareExplicitSortNumbers(a, b);
  if (explicitNumberCompared != 0) return explicitNumberCompared;

  final left = _normalizeNaturalName(a);
  final right = _normalizeNaturalName(b);
  var leftIndex = 0;
  var rightIndex = 0;
  int? leadingZeroTie;

  while (leftIndex < left.length && rightIndex < right.length) {
    final leftDigit = _isAsciiDigit(left.codeUnitAt(leftIndex));
    final rightDigit = _isAsciiDigit(right.codeUnitAt(rightIndex));

    if (leftDigit && rightDigit) {
      final leftEnd = _digitRunEnd(left, leftIndex);
      final rightEnd = _digitRunEnd(right, rightIndex);
      final compared = _compareDigitRuns(
        left.substring(leftIndex, leftEnd),
        right.substring(rightIndex, rightEnd),
      );
      if (compared != 0) return compared;
      if (leftEnd - leftIndex != rightEnd - rightIndex) {
        leadingZeroTie ??= (leftEnd - leftIndex).compareTo(
          rightEnd - rightIndex,
        );
      }
      leftIndex = leftEnd;
      rightIndex = rightEnd;
      continue;
    }

    if (leftDigit != rightDigit) {
      return leftDigit ? -1 : 1;
    }

    final leftEnd = _textRunEnd(left, leftIndex);
    final rightEnd = _textRunEnd(right, rightIndex);
    final compared = left
        .substring(leftIndex, leftEnd)
        .compareTo(right.substring(rightIndex, rightEnd));
    if (compared != 0) return compared;
    leftIndex = leftEnd;
    rightIndex = rightEnd;
  }

  final byNormalizedLength = (left.length - leftIndex).compareTo(
    right.length - rightIndex,
  );
  if (byNormalizedLength != 0) return byNormalizedLength;
  if (leadingZeroTie != null) return leadingZeroTie;

  final byCaseInsensitiveName = a.toLowerCase().compareTo(b.toLowerCase());
  if (byCaseInsensitiveName != 0) return byCaseInsensitiveName;
  return a.compareTo(b);
}

int _compareExplicitSortNumbers(String a, String b) {
  final left = _explicitSortNumber(a);
  final right = _explicitSortNumber(b);
  if (left == null || right == null) {
    if (left == right) return 0;
    return left == null ? 1 : -1;
  }
  return _compareDigitRuns(left, right);
}

String? _explicitSortNumber(String value) {
  final normalized = _normalizeFullWidth(value).trim();
  final leading = RegExp(r'^(\d+)').firstMatch(normalized);
  if (leading != null) return leading.group(1);

  final withoutExtension = normalized.replaceFirst(RegExp(r'\.[^./\\]+$'), '');
  return RegExp(
    r'(?:\s|[_‐‑‒–—−-])+(\d+)\s*$',
  ).firstMatch(withoutExtension)?.group(1);
}

String _normalizeNaturalName(String value) {
  var normalized = _normalizeFullWidth(value).toLowerCase();
  normalized = normalized.replaceAllMapped(
    RegExp(r'第?([〇零○一二两三四五六七八九十百千万亿]+)(?=[季集话章部卷期])'),
    (match) {
      final number = _parseChineseNumber(match.group(1)!);
      if (number == null) return match.group(0)!;
      final hasPrefix = match.group(0)!.startsWith('第');
      return '${hasPrefix ? '第' : ''}$number';
    },
  );
  normalized = normalized.replaceAllMapped(
    RegExp(
      r'\b(season|series|part|vol(?:ume)?|disc|disk|cd)[\s._-]*([ivxlcdm]+)\b',
    ),
    (match) {
      final number = _parseRomanNumber(match.group(2)!);
      return number == null ? match.group(0)! : '${match.group(1)}$number';
    },
  );
  return _normalizeSeparators(normalized);
}

String _normalizeFullWidth(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune == 0x3000) {
      buffer.write(' ');
    } else if (rune >= 0xff01 && rune <= 0xff5e) {
      buffer.writeCharCode(rune - 0xfee0);
    } else if (const {
      0x2010,
      0x2011,
      0x2012,
      0x2013,
      0x2014,
      0x2212,
    }.contains(rune)) {
      buffer.write('-');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

String _normalizeSeparators(String value) {
  return value.replaceAllMapped(RegExp(r'[\s._\-\[\](){}【】（）《》]+'), (match) {
    final beforeIsDigit =
        match.start > 0 && _isAsciiDigit(value.codeUnitAt(match.start - 1));
    final afterIsDigit =
        match.end < value.length && _isAsciiDigit(value.codeUnitAt(match.end));
    // 数字之间保留统一分段符，防止 1.10 被合并成 110。
    return beforeIsDigit && afterIsDigit ? '.' : '';
  });
}

int _digitRunEnd(String value, int start) {
  var index = start;
  while (index < value.length && _isAsciiDigit(value.codeUnitAt(index))) {
    index++;
  }
  return index;
}

int _textRunEnd(String value, int start) {
  var index = start;
  while (index < value.length && !_isAsciiDigit(value.codeUnitAt(index))) {
    index++;
  }
  return index;
}

bool _isAsciiDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

int _compareDigitRuns(String a, String b) {
  final left = a.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final right = b.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final byLength = left.length.compareTo(right.length);
  if (byLength != 0) return byLength;
  return left.compareTo(right);
}

int? _parseChineseNumber(String value) {
  const digits = <String, int>{
    '〇': 0,
    '零': 0,
    '○': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const units = <String, int>{
    '十': 10,
    '百': 100,
    '千': 1000,
    '万': 10000,
    '亿': 100000000,
  };

  if (!value.split('').any(units.containsKey)) {
    final raw = value.split('').map((char) => digits[char]).toList();
    if (raw.any((digit) => digit == null)) return null;
    return int.tryParse(raw.join());
  }

  var total = 0;
  var section = 0;
  var number = 0;
  for (final char in value.split('')) {
    final digit = digits[char];
    if (digit != null) {
      number = digit;
      continue;
    }
    final unit = units[char];
    if (unit == null) return null;
    if (unit < 10000) {
      section += (number == 0 ? 1 : number) * unit;
    } else {
      section += number;
      total += section * unit;
      section = 0;
    }
    number = 0;
  }
  return total + section + number;
}

int? _parseRomanNumber(String value) {
  const values = <String, int>{
    'i': 1,
    'v': 5,
    'x': 10,
    'l': 50,
    'c': 100,
    'd': 500,
    'm': 1000,
  };
  var total = 0;
  var previous = 0;
  for (final char in value.toLowerCase().split('').reversed) {
    final current = values[char];
    if (current == null) return null;
    if (current < previous) {
      total -= current;
    } else {
      total += current;
      previous = current;
    }
  }
  return total == 0 ? null : total;
}
