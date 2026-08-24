import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/profile_credential_store.dart';

void main() {
  test('Windows 凭据管理器把不存在的档案识别为未保存', () async {
    if (!Platform.isWindows) return;
    const store = WindowsProfileCredentialStore();
    final profileId =
        'missing-credential-${DateTime.now().microsecondsSinceEpoch}';

    expect(await store.read(profileId), isNull);
  });
}
