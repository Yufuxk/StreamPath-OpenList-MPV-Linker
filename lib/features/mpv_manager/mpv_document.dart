import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

enum MpvDocumentKind { options, input, scriptOptions, source }

enum MpvLineKind { blank, comment, section, entry, invalid }

class MpvManagerException implements Exception {
  const MpvManagerException(this.code, [this.detail = '']);
  final String code;
  final String detail;
  @override
  String toString() => '$code: $detail';
}

class MpvTextEdit {
  const MpvTextEdit(this.start, this.end, this.expected, this.replacement);
  final int start, end;
  final List<int> expected, replacement;
}

class MpvLine {
  const MpvLine({
    required this.start,
    required this.end,
    required this.contentEnd,
    required this.number,
    required this.kind,
    required this.scope,
    required this.block,
    this.key = '',
    this.value = '',
    this.enabled = true,
    this.tokenStart = 0,
    this.valueStart = 0,
    this.valueEnd = 0,
    this.quote = '',
    this.lengthStart,
    this.lengthEnd,
    this.inputSection = '',
    this.menuPath = '',
    this.menuStart,
    this.menuEnd,
    this.menuOnly = false,
  });
  final int start, end, contentEnd, number, block;
  final MpvLineKind kind;
  final String scope, key, value, quote, inputSection;
  final bool enabled;
  final int tokenStart, valueStart, valueEnd;
  final int? lengthStart, lengthEnd;
  final String menuPath;
  final int? menuStart, menuEnd;
  final bool menuOnly;
}

/// 字节位置是编辑依据；界面的字符串只用于显示和输入。
class MpvDocumentSnapshot {
  MpvDocumentSnapshot._(this.path, this.kind, Uint8List source, this.exists)
    : bytes = source.asUnmodifiableView(),
      revision = sha256.convert(source).toString() {
    try {
      text = utf8.decode(source);
    } on FormatException {
      text = null;
    }
    lines = text == null || kind == MpvDocumentKind.source
        ? const []
        : _parse(source, kind);
  }

  factory MpvDocumentSnapshot.parse(
    String path,
    List<int> bytes,
    MpvDocumentKind kind, {
    bool exists = true,
  }) => MpvDocumentSnapshot._(path, kind, Uint8List.fromList(bytes), exists);

  final String path;
  final MpvDocumentKind kind;
  final Uint8List bytes;
  final bool exists;
  final String revision;
  late final String? text;
  late final List<MpvLine> lines;

  Iterable<MpvLine> get entries =>
      lines.where((l) => l.kind == MpvLineKind.entry);
  bool get hasBom =>
      bytes.length >= 3 &&
      bytes[0] == 239 &&
      bytes[1] == 187 &&
      bytes[2] == 191;

  MpvTextEdit edit(int start, int end, List<int> replacement) =>
      MpvTextEdit(start, end, bytes.sublist(start, end), replacement);

  List<int> apply(List<MpvTextEdit> changes) {
    if (text == null) throw const MpvManagerException('encoding');
    final sorted = [...changes]..sort((a, b) => a.start.compareTo(b.start));
    final result = BytesBuilder(copy: false);
    var cursor = 0;
    for (final change in sorted) {
      if (change.start < cursor ||
          change.end < change.start ||
          change.end > bytes.length ||
          !_same(bytes.sublist(change.start, change.end), change.expected)) {
        throw const MpvManagerException('conflict');
      }
      result.add(bytes.sublist(cursor, change.start));
      result.add(change.replacement);
      cursor = change.end;
    }
    result.add(bytes.sublist(cursor));
    final output = result.takeBytes();
    utf8.decode(output);
    return output;
  }

  List<MpvTextEdit> setValue(MpvLine line, String value) {
    if (value.contains('\n') || value.contains('\r')) {
      throw const MpvManagerException('singleLine');
    }
    if (line.value == value) return [];
    if (kind == MpvDocumentKind.input ||
        kind == MpvDocumentKind.scriptOptions) {
      if (kind == MpvDocumentKind.input &&
          _inputComment(value) != value.length) {
        throw const MpvManagerException('commandComment');
      }
      return [
        edit(
          line.valueStart,
          line.valueEnd,
          utf8.encode(
            '$value${line.menuOnly && line.value.isEmpty ? ' ' : ''}',
          ),
        ),
      ];
    }
    final encoded = utf8.encode(value);
    if (line.lengthStart != null) {
      return [
        edit(
          line.lengthStart!,
          line.lengthEnd!,
          ascii.encode('${encoded.length}'),
        ),
        edit(line.valueStart, line.valueEnd, encoded),
      ];
    }
    if (line.quote.isNotEmpty && !value.contains(line.quote)) {
      return [edit(line.valueStart, line.valueEnd, encoded)];
    }
    final needsQuotes =
        value.contains('#') ||
        value.startsWith('%') ||
        value.startsWith('"') ||
        value.startsWith("'") ||
        value.trim() != value;
    String rendered = value;
    if (line.quote.isNotEmpty || needsQuotes) {
      rendered = !value.contains('"')
          ? '"$value"'
          : !value.contains("'")
          ? "'$value'"
          : '%${encoded.length}%$value';
    }
    final start = line.quote.isEmpty ? line.valueStart : line.valueStart - 1;
    final end = line.quote.isEmpty ? line.valueEnd : line.valueEnd + 1;
    // 无值开关需要补上等号，而不是在参数名后直接追加值。
    final before = latin1.decode(
      bytes.sublist(line.tokenStart, line.valueStart),
    );
    return [
      edit(
        start,
        end,
        utf8.encode('${before.contains('=') ? '' : '='}$rendered'),
      ),
    ];
  }

  List<MpvTextEdit> setKey(MpvLine line, String key) {
    final pattern = kind == MpvDocumentKind.input
        ? RegExp(r'^[^\s#]+$')
        : RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_-]*$');
    if (!pattern.hasMatch(key)) throw const MpvManagerException('key');
    return [
      edit(
        line.tokenStart,
        line.tokenStart + utf8.encode(line.key).length,
        utf8.encode(key),
      ),
    ];
  }

  List<MpvTextEdit> setEnabled(MpvLine line, bool enabled) {
    if (line.menuOnly) throw const MpvManagerException('key');
    if (line.enabled == enabled) return [];
    var marker = line.start;
    if (kind == MpvDocumentKind.scriptOptions) {
      return [
        enabled ? edit(marker, marker + 1, []) : edit(marker, marker, [35]),
      ];
    }
    while (marker < line.contentEnd &&
        (bytes[marker] == 32 || bytes[marker] == 9)) {
      marker++;
    }
    return [
      enabled ? edit(marker, marker + 1, []) : edit(marker, marker, [35]),
    ];
  }

  List<MpvTextEdit> remove(MpvLine line) => [edit(line.start, line.end, [])];

  List<MpvTextEdit> setMenuPath(MpvLine line, String value) {
    if (kind != MpvDocumentKind.input ||
        value.contains('\n') ||
        value.contains('\r')) {
      throw const MpvManagerException('singleLine');
    }
    if (value == line.menuPath) return [];
    return line.menuStart != null
        ? [edit(line.menuStart!, line.menuEnd!, utf8.encode(value))]
        : [
            edit(
              line.contentEnd,
              line.contentEnd,
              utf8.encode(' #menu: $value'),
            ),
          ];
  }

  List<MpvTextEdit> replaceText(String value) {
    if (text == null) throw const MpvManagerException('encoding');
    final updated = utf8.encode(value).toList();
    if (hasBom &&
        !(updated.length >= 3 &&
            updated[0] == 239 &&
            updated[1] == 187 &&
            updated[2] == 191)) {
      updated.insertAll(0, [239, 187, 191]);
    }
    var start = 0;
    while (start < bytes.length &&
        start < updated.length &&
        bytes[start] == updated[start]) {
      start++;
    }
    var oldEnd = bytes.length, newEnd = updated.length;
    while (oldEnd > start &&
        newEnd > start &&
        bytes[oldEnd - 1] == updated[newEnd - 1]) {
      oldEnd--;
      newEnd--;
    }
    return start == oldEnd && start == newEnd
        ? []
        : [edit(start, oldEnd, updated.sublist(start, newEnd))];
  }

  List<MpvTextEdit> addEntry(String key, String value, {int block = 0}) {
    final pattern = kind == MpvDocumentKind.input
        ? RegExp(r'^[^\s#]+$')
        : RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_-]*$');
    if (!pattern.hasMatch(key) ||
        value.contains('\n') ||
        value.contains('\r')) {
      throw const MpvManagerException('key');
    }
    var position = bytes.length;
    final next = lines.where(
      (l) => l.kind == MpvLineKind.section && l.block > block,
    );
    if (next.isNotEmpty) position = next.first.start;
    final newline = text!.contains('\r\n') ? '\r\n' : '\n';
    final prefix =
        position > (hasBom ? 3 : 0) &&
            bytes[position - 1] != 10 &&
            bytes[position - 1] != 13
        ? newline
        : '';
    String entry;
    if (kind == MpvDocumentKind.options) {
      final quoted =
          value.contains('#') ||
          value.startsWith('%') ||
          value.startsWith('"') ||
          value.startsWith("'") ||
          value.trim() != value;
      final output = quoted ? '%${utf8.encode(value).length}%$value' : value;
      entry = '$key=$output';
    } else {
      entry = '$key${kind == MpvDocumentKind.input ? ' ' : '='}$value';
    }
    return [edit(position, position, utf8.encode('$prefix$entry$newline'))];
  }

  List<MpvTextEdit> addProfile(String name) {
    if (name.isEmpty || name.contains(RegExp(r'[\[\]\r\n]'))) {
      throw const MpvManagerException('key');
    }
    final newline = text!.contains('\r\n') ? '\r\n' : '\n';
    final prefix = bytes.isNotEmpty && bytes.last != 10 ? newline : '';
    return [
      edit(bytes.length, bytes.length, utf8.encode('$prefix[$name]$newline')),
    ];
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _inputComment(String value) {
  var quote = '', escape = false;
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (char == r'\') {
      escape = true;
      continue;
    }
    if (quote.isNotEmpty) {
      if (char == quote) quote = '';
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (char == '#') return i;
  }
  return value.length;
}

List<MpvLine> _parse(Uint8List bytes, MpvDocumentKind kind) {
  final output = <MpvLine>[];
  var start =
      bytes.length >= 3 && bytes[0] == 239 && bytes[1] == 187 && bytes[2] == 191
      ? 3
      : 0;
  var scope = '', block = 0, number = 0;
  while (start < bytes.length) {
    var end = start;
    while (end < bytes.length && bytes[end] != 10 && bytes[end] != 13) {
      end++;
    }
    final contentEnd = end;
    if (end < bytes.length && bytes[end] == 13) end++;
    if (end < bytes.length && bytes[end] == 10) end++;
    final raw = latin1.decode(bytes.sublist(start, contentEnd));
    number++;
    var token = raw.length - raw.trimLeft().length;
    var lineKind = MpvLineKind.entry, enabled = true;
    final menuComment = token < raw.length
        ? token + 1 + _inputComment(raw.substring(token + 1))
        : raw.length;
    final menuOnly =
        kind == MpvDocumentKind.input &&
        RegExp(r'^\s*#\s+').hasMatch(raw) &&
        RegExp(r'#(?:menu:|!)').matchAsPrefix(raw, menuComment) != null;
    if (token == raw.length) lineKind = MpvLineKind.blank;
    if (kind == MpvDocumentKind.scriptOptions &&
        lineKind == MpvLineKind.entry) {
      token = 0;
    }
    if (token < raw.length && raw[token] == '#' && !menuOnly) {
      final rest = raw.substring(token + 1);
      if ((kind == MpvDocumentKind.options ||
                  kind == MpvDocumentKind.scriptOptions) &&
              RegExp(
                r'^\s*(?:--)?[A-Za-z0-9_][A-Za-z0-9_-]*\s*=',
              ).hasMatch(rest) ||
          kind == MpvDocumentKind.options &&
              RegExp(r'^(?:--)?[A-Za-z0-9_][A-Za-z0-9_-]*$').hasMatch(rest) ||
          kind == MpvDocumentKind.input &&
              RegExp(r'^\S+\s+\S').hasMatch(rest) &&
              !rest.startsWith('#')) {
        enabled = false;
        token++;
        if (kind == MpvDocumentKind.options) {
          token += rest.length - rest.trimLeft().length;
        }
      } else {
        lineKind = MpvLineKind.comment;
      }
    }
    final section = kind == MpvDocumentKind.options && enabled
        ? RegExp(r'^\[([^\]]+)\]\s*(?:#.*)?$').firstMatch(raw.substring(token))
        : null;
    if (section != null) {
      block++;
      scope = utf8.decode(latin1.encode(section[1]!));
      lineKind = MpvLineKind.section;
    }
    String key = '', value = '', quote = '', inputSection = '';
    String menuPath = '';
    int? menuStart, menuEnd;
    var valueStart = contentEnd, valueEnd = contentEnd;
    int? lengthStart, lengthEnd;
    if (lineKind == MpvLineKind.entry) {
      var pos = token;
      if (kind == MpvDocumentKind.options &&
          raw.substring(pos).startsWith('--')) {
        pos += 2;
        token += 2;
      }
      final match =
          (menuOnly
                  ? RegExp(r'#')
                  : kind == MpvDocumentKind.input
                  ? RegExp(r'[^\s#]+')
                  : kind == MpvDocumentKind.scriptOptions
                  ? RegExp(r'[^=]+')
                  : RegExp(r'[A-Za-z0-9_][A-Za-z0-9_-]*'))
              .matchAsPrefix(raw, pos);
      if (match == null) {
        lineKind = MpvLineKind.invalid;
      } else {
        key = utf8.decode(latin1.encode(match[0]!));
        pos = match.end;
        if (kind != MpvDocumentKind.scriptOptions) {
          while (pos < raw.length && (raw[pos] == ' ' || raw[pos] == '\t')) {
            pos++;
          }
        }
        if (kind == MpvDocumentKind.input) {
          if (pos < raw.length && raw[pos] == '{') {
            final close = raw.indexOf('}', pos);
            if (close >= 0) {
              inputSection = raw.substring(pos + 1, close);
              pos = close + 1;
            }
            while (pos < raw.length && (raw[pos] == ' ' || raw[pos] == '\t')) {
              pos++;
            }
          }
          valueStart = start + pos;
          valueEnd = start + _inputComment(raw.substring(pos)) + pos;
          final menu = RegExp(
            r'#(?:menu:|!)\s*',
          ).matchAsPrefix(raw, valueEnd - start);
          if (menu != null) {
            menuStart = start + menu.end;
            menuEnd =
                menuStart + _inputComment(raw.substring(menuStart - start));
            while (menuEnd! > menuStart &&
                (bytes[menuEnd - 1] == 32 || bytes[menuEnd - 1] == 9)) {
              menuEnd--;
            }
            menuPath = utf8.decode(bytes.sublist(menuStart, menuEnd));
          }
          while (valueEnd > valueStart &&
              (bytes[valueEnd - 1] == 32 || bytes[valueEnd - 1] == 9)) {
            valueEnd--;
          }
          if (valueStart == valueEnd && !menuOnly) {
            lineKind = MpvLineKind.invalid;
          }
        } else if (pos < raw.length && raw[pos] == '=') {
          pos++;
          if (kind == MpvDocumentKind.options) {
            while (pos < raw.length && (raw[pos] == ' ' || raw[pos] == '\t')) {
              pos++;
            }
          }
          valueStart = start + pos;
          valueEnd = contentEnd;
          if (kind == MpvDocumentKind.options && pos < raw.length) {
            if (raw[pos] == '"' || raw[pos] == "'") {
              quote = raw[pos];
              final close = raw.indexOf(quote, pos + 1);
              if (close < 0) {
                lineKind = MpvLineKind.invalid;
              } else {
                valueStart++;
                valueEnd = start + close;
                if (!RegExp(
                  r'^\s*(?:#.*)?$',
                ).hasMatch(raw.substring(close + 1))) {
                  lineKind = MpvLineKind.invalid;
                }
              }
            } else if (raw[pos] == '%') {
              final fixed = RegExp(r'^%(\d+)%').firstMatch(raw.substring(pos));
              if (fixed == null) {
                lineKind = MpvLineKind.invalid;
              } else {
                lengthStart = start + pos + 1;
                lengthEnd = lengthStart + fixed[1]!.length;
                valueStart = start + pos + fixed[0]!.length;
                valueEnd = valueStart + int.parse(fixed[1]!);
                if (valueEnd > contentEnd ||
                    !RegExp(
                      r'^\s*(?:#.*)?$',
                    ).hasMatch(raw.substring(valueEnd - start))) {
                  lineKind = MpvLineKind.invalid;
                }
              }
            } else {
              final hash = raw.indexOf('#', pos);
              valueEnd = hash < 0 ? contentEnd : start + hash;
              while (valueEnd > valueStart &&
                  (bytes[valueEnd - 1] == 32 || bytes[valueEnd - 1] == 9)) {
                valueEnd--;
              }
            }
          }
        } else if (kind == MpvDocumentKind.scriptOptions ||
            pos < raw.length && raw[pos] != '#') {
          lineKind = MpvLineKind.invalid;
        } else {
          valueStart = valueEnd = start + pos;
        }
        if (lineKind == MpvLineKind.entry) {
          try {
            value = utf8.decode(bytes.sublist(valueStart, valueEnd));
          } on FormatException {
            lineKind = MpvLineKind.invalid;
          }
        }
      }
    }
    output.add(
      MpvLine(
        start: start,
        end: end,
        contentEnd: contentEnd,
        number: number,
        kind: lineKind,
        scope: scope,
        block: block,
        key: key,
        value: value,
        enabled: enabled,
        tokenStart: start + token,
        valueStart: valueStart,
        valueEnd: valueEnd,
        quote: quote,
        lengthStart: lengthStart,
        lengthEnd: lengthEnd,
        inputSection: inputSection,
        menuPath: menuPath,
        menuStart: menuStart,
        menuEnd: menuEnd,
        menuOnly: menuOnly,
      ),
    );
    start = end;
  }
  return List.unmodifiable(output);
}
