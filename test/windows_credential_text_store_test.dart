import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/windows_credential_text_store.dart';

void main() {
  test(
    'missing Windows credential remains absent on the first FFI error lookup',
    () async {
      final store = WindowsCredentialTextStore(
        'StreamPath/test-text/${DateTime.now().microsecondsSinceEpoch}',
      );
      expect(await store.read(), isNull);
      await store.delete();
      await store.write('{"test":"测试"}');
      try {
        expect(await store.read(), '{"test":"测试"}');
        await store.write('{"test":"updated"}');
        expect(await store.read(), '{"test":"updated"}');
      } finally {
        await store.delete();
      }
      expect(await store.read(), isNull);
    },
    skip: !Platform.isWindows,
  );
}
