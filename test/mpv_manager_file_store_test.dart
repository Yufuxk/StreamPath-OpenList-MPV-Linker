import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/features/mpv_manager/mpv_document.dart';
import 'package:streampath/features/mpv_manager/mpv_file_store.dart';

void main() {
  late Directory temp;
  late MpvFileStore store;
  late File file;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('mpv_manager_store_');
    store = MpvFileStore(p.join(temp.path, 'history'));
    file = File(p.join(temp.path, 'mpv.conf'))
      ..writeAsBytesSync(utf8.encode('\uFEFFvolume = 20 # note\r\n'));
  });
  tearDown(() => temp.deleteSync(recursive: true));
  test(
    'atomic commit preserves unrelated bytes and records a reversible version',
    () async {
      final original = file.readAsBytesSync();
      final doc = await store.load(file.path, MpvDocumentKind.options);
      await store.commit(doc, doc.setValue(doc.entries.single, '30'));
      expect(
        file.readAsBytesSync(),
        utf8.encode('\uFEFFvolume = 30 # note\r\n'),
      );
      final history = await store.history();
      expect(history, hasLength(1));
      expect(history.single.before, original);
      await store.restore(history.single);
      expect(file.readAsBytesSync(), original);
    },
  );
  test(
    'external modifications are never overwritten by a stale snapshot',
    () async {
      final doc = await store.load(file.path, MpvDocumentKind.options);
      file.writeAsStringSync('volume=99\n');
      await expectLater(
        store.commit(doc, doc.setValue(doc.entries.single, '30')),
        throwsA(isA<MpvManagerException>()),
      );
      expect(file.readAsStringSync(), 'volume=99\n');
      expect(await store.history(), isEmpty);
    },
  );
  test('restore rejects changes after the original save', () async {
    final doc = await store.load(file.path, MpvDocumentKind.options);
    await store.commit(doc, doc.setValue(doc.entries.single, '30'));
    final history = await store.history();
    file.writeAsStringSync('volume=99');
    await expectLater(
      store.restore(history.single),
      throwsA(isA<MpvManagerException>()),
    );
    expect(file.readAsStringSync(), 'volume=99');
  });
  test('no-op leaves timestamp and history untouched', () async {
    final before = file.statSync().modified;
    final doc = await store.load(file.path, MpvDocumentKind.options);
    await store.commit(doc, []);
    expect(file.statSync().modified, before);
    expect(await store.history(), isEmpty);
  });
  test('new files are published only by actual edits', () async {
    final path = p.join(temp.path, 'script-opts', 'x.conf');
    final doc = await store.load(path, MpvDocumentKind.scriptOptions);
    expect(File(path).existsSync(), isFalse);
    await store.commit(doc, doc.addEntry('enabled', 'yes'));
    expect(File(path).readAsStringSync(), 'enabled=yes\n');
  });
  test('new destination appearing after scan is a conflict', () async {
    final path = p.join(temp.path, 'new.conf');
    final doc = await store.load(path, MpvDocumentKind.options);
    File(path).writeAsStringSync('volume=80');
    await expectLater(
      store.commit(doc, doc.addEntry('volume', '30')),
      throwsA(isA<MpvManagerException>()),
    );
    expect(File(path).readAsStringSync(), 'volume=80');
  });
  test(
    'script enable and disable preserve content and refuse collisions',
    () async {
      final script = File(p.join(temp.path, 'example.lua'))
        ..writeAsStringSync('return 1');
      final disabled = await store.renameScript(script.path, false);
      expect(File(disabled).readAsStringSync(), 'return 1');
      expect(script.existsSync(), isFalse);
      script.writeAsStringSync('return 2');
      await expectLater(
        store.renameScript(disabled, true),
        throwsA(isA<MpvManagerException>()),
      );
      expect(script.readAsStringSync(), 'return 2');
    },
  );
  test(
    'failed writes do not poison subsequent independent operations',
    () async {
      final old = await store.load(file.path, MpvDocumentKind.options);
      file.writeAsStringSync('volume=10');
      await expectLater(
        store.commit(old, old.setValue(old.entries.single, '30')),
        throwsA(isA<MpvManagerException>()),
      );
      final fresh = await store.load(file.path, MpvDocumentKind.options);
      await store.commit(fresh, fresh.setValue(fresh.entries.single, '40'));
      expect(file.readAsStringSync(), 'volume=40');
    },
  );

  test('locked files fail without truncating their original content', () async {
    final doc = await store.load(file.path, MpvDocumentKind.options);
    final path = file.path.toNativeUtf16();
    final handle = CreateFile(
      path,
      GENERIC_READ,
      0,
      nullptr,
      OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL,
      NULL,
    );
    try {
      expect(handle, isNot(INVALID_HANDLE_VALUE));
      await expectLater(
        store.commit(doc, doc.setValue(doc.entries.single, '30')),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
      calloc.free(path);
    }
    expect(file.readAsBytesSync(), doc.bytes);
  });

  test(
    'read-only files keep their original bytes on replace failure',
    () async {
      final doc = await store.load(file.path, MpvDocumentKind.options);
      final path = file.path.toNativeUtf16();
      try {
        expect(SetFileAttributes(path, FILE_ATTRIBUTE_READONLY), isNot(0));
        await expectLater(
          store.commit(doc, doc.setValue(doc.entries.single, '30')),
          throwsA(isA<MpvManagerException>()),
        );
        expect(file.readAsBytesSync(), doc.bytes);
      } finally {
        SetFileAttributes(path, FILE_ATTRIBUTE_NORMAL);
        calloc.free(path);
      }
    },
  );

  test('manual associations survive a new manager instance', () async {
    await store.associate('example.lua', file.path);
    expect(await MpvFileStore(store.historyDirectory).associations(), {
      mpvScriptAssociationKey('example.lua'): file.path,
    });
    expect(await store.history(), isEmpty);
  });

  test('history retention is bounded to the latest 50 edits', () async {
    var doc = await store.load(file.path, MpvDocumentKind.options);
    for (var i = 30; i < 83; i++) {
      doc = await store.commit(doc, doc.setValue(doc.entries.single, '$i'));
    }
    expect(await store.history(), hasLength(50));
    expect(file.readAsStringSync(), 'volume = 82 # note\r\n');
  });

  test('staged records remain recoverable after replacement', () async {
    final doc = await store.load(file.path, MpvDocumentKind.options);
    await store.commit(doc, doc.setValue(doc.entries.single, '30'));
    final record = File((await store.history()).single.recordPath);
    final json = jsonDecode(record.readAsStringSync()) as Map<String, dynamic>;
    json['committed'] = false;
    record.writeAsStringSync(jsonEncode(json));
    final staged = await store.history();
    expect(staged, hasLength(1));
    await store.restore(staged.single);
    expect(file.readAsBytesSync(), doc.bytes);
  });

  test(
    'junction paths write through to the real target without replacing the link',
    () async {
      final target = Directory(p.join(temp.path, 'real'))..createSync();
      final actual = File(p.join(target.path, 'mpv.conf'))
        ..writeAsStringSync('volume=20');
      final alias = p.join(temp.path, 'linked');
      String quoted(String value) => "'${value.replaceAll("'", "''")}'";
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'New-Item -ItemType Junction -Path ${quoted(alias)} -Target ${quoted(target.path)} | Out-Null',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final doc = await store.load(
        p.join(alias, 'mpv.conf'),
        MpvDocumentKind.options,
      );
      expect(doc.path, actual.resolveSymbolicLinksSync());
      await store.commit(doc, doc.setValue(doc.entries.single, '30'));
      expect(actual.readAsStringSync(), 'volume=30');
      expect(Directory(alias).existsSync(), isTrue);
      final linkType = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '(Get-Item -LiteralPath ${quoted(alias)}).LinkType',
      ]);
      expect('${linkType.stdout}'.trim(), 'Junction');
      Link(alias).deleteSync();
    },
  );
}
