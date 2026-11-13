import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/domain/services/bd_java_runtime.dart';

void main() {
  test('真实随包 Java 与 JAR 通过完整性检查', () async {
    final root = Directory('build/windows/x64/bdj-runtime').absolute;
    if (!await root.exists()) {
      markTestSkipped('Build the bundled runtime first');
      return;
    }
    final data = await Directory.systemTemp.createTemp('bdj-real-');
    addTearDown(() => data.delete(recursive: true));
    final env = (await BdJavaRuntime(
      root: root.path,
    ).environment(data, required: true))!;
    final result = await Process.run(
      p.join(env['JAVA_HOME']!, 'bin', 'java.exe'),
      ['-version'],
      environment: env,
    );
    expect(result.exitCode, 0);
    expect(result.stderr, contains('17.0.21'));
  });

  test('缺少 Java 不阻塞 HDMV，需要 BD-J 时明确失败', () async {
    final root = await Directory.systemTemp.createTemp('bdj-missing-');
    addTearDown(() => root.delete(recursive: true));
    final runtime = BdJavaRuntime(root: p.join(root.path, 'absent'));
    expect(await runtime.environment(root), isNull);
    await expectLater(
      runtime.environment(root, required: true),
      throwsException,
    );
  });

  test('环境只指向随包文件，建立可写目录并拒绝损坏的 JAR', () async {
    final root = await Directory.systemTemp.createTemp('bdj-runtime-');
    addTearDown(() => root.delete(recursive: true));
    final files = <String, String>{};
    for (final name in [
      'java/bin/server/jvm.dll',
      'libbluray-j2se-1.5.0.jar',
      'libbluray-awt-j2se-1.5.0.jar',
    ]) {
      final file = File(p.join(root.path, name));
      await file.parent.create(recursive: true);
      await file.writeAsString(name);
      files[name] = sha256.convert(utf8.encode(name)).toString();
    }
    await File(p.join(root.path, 'runtime-manifest.json')).writeAsString(
      jsonEncode({'schema': 1, 'architecture': 'x64', 'files': files}),
    );
    final previous = Platform.environment['JAVA_HOME'];
    final runtime = BdJavaRuntime(root: root.path);
    final environment = (await runtime.environment(
      Directory(p.join(root.path, '可写 数据')),
      required: true,
    ))!;
    expect(environment['JAVA_HOME'], p.join(root.path, 'java'));
    expect(File(environment['LIBBLURAY_CP']!).isAbsolute, isTrue);
    expect(
      await Directory(environment['LIBBLURAY_CACHE_ROOT']!).exists(),
      isTrue,
    );
    expect(Platform.environment['JAVA_HOME'], previous);
    expect(environment.containsKey('PATH'), isFalse);
    await File(environment['LIBBLURAY_CP']!).writeAsString('damaged');
    await expectLater(
      runtime.environment(root, required: true),
      throwsException,
    );
  });
}
