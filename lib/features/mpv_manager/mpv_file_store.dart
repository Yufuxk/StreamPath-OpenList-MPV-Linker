import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'mpv_document.dart';

typedef _ReplaceNative =
    Int32 Function(
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Uint32,
      Pointer<Void>,
      Pointer<Void>,
    );
typedef _ReplaceDart =
    int Function(
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Utf16>,
      int,
      Pointer<Void>,
      Pointer<Void>,
    );
typedef _LastErrorNative = Uint32 Function();
typedef _LastErrorDart = int Function();
typedef _MoveNative = Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _MoveDart = int Function(Pointer<Utf16>, Pointer<Utf16>, int);

class MpvHistoryEntry {
  const MpvHistoryEntry(
    this.recordPath,
    this.path,
    this.time,
    this.before,
    this.after,
    this.kind,
  );
  final String recordPath, path;
  final DateTime time;
  final List<int> before, after;
  final MpvDocumentKind kind;
}

/// 文件修改只从此处提交；磁盘操作与原生调用均在后台 isolate 完成。
class MpvFileStore {
  MpvFileStore(this.historyDirectory);
  final String historyDirectory;
  Future<void> _tail = Future.value();

  Future<MpvDocumentSnapshot> load(String path, MpvDocumentKind kind) =>
      Isolate.run(() => _load(path, kind));

  Future<MpvDocumentSnapshot> commit(
    MpvDocumentSnapshot document,
    List<MpvTextEdit> edits,
  ) {
    final historyRoot = historyDirectory;
    final result = _tail.then(
      (_) => Isolate.run(() => _commit(document, edits, historyRoot)),
    );
    // 提交失败不影响后续独立操作；错误仍交给当前调用方。
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    return result;
  }

  Future<List<MpvHistoryEntry>> history() {
    final historyRoot = historyDirectory;
    return Isolate.run(() {
      final dir = Directory(historyRoot);
      if (!dir.existsSync()) return <MpvHistoryEntry>[];
      final result = <MpvHistoryEntry>[];
      for (final file
          in dir
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()) {
        if (!file.path.endsWith('.json')) continue;
        final data =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        if (data['committed'] != true) {
          final target = File(data['path'] as String? ?? '');
          final backup = File(data['backup'] as String? ?? '');
          if (backup.existsSync()) {
            data['before'] = base64Encode(backup.readAsBytesSync());
            if (!target.existsSync()) data['after'] = '';
          } else if (!target.existsSync() ||
              base64Encode(target.readAsBytesSync()) != data['after']) {
            continue;
          }
        }
        result.add(
          MpvHistoryEntry(
            file.path,
            data['path'] as String,
            DateTime.parse(data['time'] as String),
            base64Decode(data['before'] as String),
            base64Decode(data['after'] as String),
            MpvDocumentKind.values.byName(data['kind'] as String),
          ),
        );
      }
      result.sort((a, b) => b.time.compareTo(a.time));
      return result;
    });
  }

  Future<MpvDocumentSnapshot> restore(MpvHistoryEntry entry) async {
    final doc = await load(entry.path, entry.kind);
    if (sha256.convert(doc.bytes).toString() !=
        sha256.convert(entry.after).toString()) {
      throw const MpvManagerException('conflict');
    }
    return commit(doc, [doc.edit(0, doc.bytes.length, entry.before)]);
  }

  Future<String> renameScript(String path, bool enabled) {
    final result = _tail.then(
      (_) => Isolate.run(() {
        final target = enabled
            ? path.substring(0, path.length - '.disable'.length)
            : '$path.disable';
        if (FileSystemEntity.typeSync(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const MpvManagerException('destinationExists');
        }
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        if (type == FileSystemEntityType.link) {
          throw const MpvManagerException('scriptLink');
        }
        if (type == FileSystemEntityType.directory) {
          Directory(path).renameSync(target);
        } else if (type == FileSystemEntityType.file) {
          File(path).renameSync(target);
        } else {
          throw const MpvManagerException('missing');
        }
        return target;
      }),
    );
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    return result;
  }

  Future<Map<String, String>> associations() {
    final path = p.join(historyDirectory, 'associations.json');
    return Isolate.run(() {
      final file = File(path);
      return file.existsSync()
          ? (jsonDecode(file.readAsStringSync()) as Map).cast<String, String>()
          : <String, String>{};
    });
  }

  Future<void> associate(String script, String config) {
    final path = p.join(historyDirectory, 'associations.json');
    final result = _tail.then(
      (_) => Isolate.run(() {
        final file = File(path);
        final values = file.existsSync()
            ? (jsonDecode(file.readAsStringSync()) as Map)
                  .cast<String, String>()
            : <String, String>{};
        values[mpvScriptAssociationKey(script)] = p.absolute(config);
        file.parent.createSync(recursive: true);
        final temporary = File('$path.tmp')
          ..writeAsStringSync(jsonEncode(values), flush: true);
        temporary.renameSync(path);
      }),
    );
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    return result;
  }
}

MpvDocumentSnapshot _load(String path, MpvDocumentKind kind) {
  final file = File(path);
  final exists = file.existsSync();
  final resolved = exists
      ? file.resolveSymbolicLinksSync()
      : p.join(
          Directory(p.dirname(path)).existsSync()
              ? Directory(p.dirname(path)).resolveSymbolicLinksSync()
              : p.absolute(p.dirname(path)),
          p.basename(path),
        );
  return MpvDocumentSnapshot.parse(
    resolved,
    exists ? file.readAsBytesSync() : [],
    kind,
    exists: exists,
  );
}

MpvDocumentSnapshot _commit(
  MpvDocumentSnapshot document,
  List<MpvTextEdit> edits,
  String historyRoot,
) {
  final output = document.apply(edits);
  final file = File(document.path);
  void checkCurrent() {
    if (file.existsSync() != document.exists ||
        document.exists &&
            sha256.convert(file.readAsBytesSync()).toString() !=
                document.revision) {
      throw const MpvManagerException('conflict');
    }
    if (file.existsSync() &&
        p.normalize(file.resolveSymbolicLinksSync()) !=
            p.normalize(document.path)) {
      throw const MpvManagerException('conflict');
    }
  }

  checkCurrent();
  if (sha256.convert(output).toString() == document.revision) return document;
  final id = '${DateTime.now().microsecondsSinceEpoch}-$pid';
  final folder = Directory(
    p.join(
      historyRoot,
      sha256
          .convert(utf8.encode(p.normalize(document.path).toLowerCase()))
          .toString(),
    ),
  );
  folder.createSync(recursive: true);
  final record = File(p.join(folder.path, '$id.json'));
  final temporary = File(p.join(file.parent.path, '.streampath-$id.tmp'));
  final backup = File(p.join(file.parent.path, '.streampath-$id.bak'));
  final data = <String, Object?>{
    'path': document.path,
    'kind': document.kind.name,
    'time': DateTime.now().toUtc().toIso8601String(),
    'before': base64Encode(document.bytes),
    'after': base64Encode(output),
    'committed': false,
    'backup': backup.path,
  };
  _writeRecord(record, data);
  file.parent.createSync(recursive: true);
  temporary.writeAsBytesSync(output, flush: true);
  var replaced = false;
  try {
    checkCurrent();
    if (document.exists && Platform.isWindows) {
      final library = DynamicLibrary.open('kernel32.dll');
      final replace = library.lookupFunction<_ReplaceNative, _ReplaceDart>(
        'ReplaceFileW',
      );
      final lastError = library
          .lookupFunction<_LastErrorNative, _LastErrorDart>('GetLastError');
      final a = document.path.toNativeUtf16(),
          b = temporary.path.toNativeUtf16(),
          c = backup.path.toNativeUtf16();
      try {
        if (replace(a, b, c, 0, nullptr, nullptr) == 0) {
          final error = lastError();
          throw MpvManagerException(
            'replaceFailed',
            '$error; ${file.path}; ${temporary.path}; ${backup.path}',
          );
        }
      } finally {
        calloc.free(a);
        calloc.free(b);
        calloc.free(c);
      }
    } else if (document.exists) {
      file.copySync(backup.path);
      temporary.renameSync(file.path);
    } else if (Platform.isWindows) {
      final library = DynamicLibrary.open('kernel32.dll');
      final move = library.lookupFunction<_MoveNative, _MoveDart>(
        'MoveFileExW',
      );
      final lastError = library
          .lookupFunction<_LastErrorNative, _LastErrorDart>('GetLastError');
      final from = temporary.path.toNativeUtf16(),
          to = file.path.toNativeUtf16();
      try {
        if (move(from, to, 0) == 0) {
          throw MpvManagerException(
            'replaceFailed',
            '${lastError()}; ${temporary.path}',
          );
        }
      } finally {
        calloc.free(from);
        calloc.free(to);
      }
    } else {
      throw const MpvManagerException('windowsOnly');
    }
    replaced = true;
    if (backup.existsSync()) {
      data['before'] = base64Encode(backup.readAsBytesSync());
    }
    data['committed'] = true;
    _writeRecord(record, data);
    if (backup.existsSync()) backup.deleteSync();
    final records =
        folder
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    for (final old in records.skip(50)) {
      old.deleteSync();
    }
    return MpvDocumentSnapshot.parse(document.path, output, document.kind);
  } on FileSystemException catch (error) {
    throw MpvManagerException(
      replaced ? 'archiveFailed' : 'io',
      '${error.osError}; ${backup.path}',
    );
  } finally {
    // 原生替换失败时保留现场，供手动恢复，绝不截断原件。
    if (!replaced &&
        !backup.existsSync() &&
        temporary.existsSync() &&
        file.existsSync() &&
        sha256.convert(file.readAsBytesSync()).toString() ==
            document.revision) {
      temporary.deleteSync();
    }
  }
}

void _writeRecord(File record, Map<String, Object?> data) {
  final temporary = File('${record.path}.tmp');
  temporary.writeAsStringSync(jsonEncode(data), flush: true);
  temporary.renameSync(record.path);
}

String mpvScriptAssociationKey(String path) => p.normalize(
  p.absolute(
    path.toLowerCase().endsWith('.disable')
        ? path.substring(0, path.length - 8)
        : path,
  ),
);
