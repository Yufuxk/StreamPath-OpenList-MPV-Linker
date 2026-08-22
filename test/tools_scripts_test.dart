import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late Directory projectDir;
  late Directory toolsDir;
  late Map<String, String> isolatedEnvironment;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('streampath_tools_');
    projectDir = Directory(p.join(tempDir.path, 'project'))..createSync();
    toolsDir = Directory(p.join(projectDir.path, 'tools'))..createSync();
    File(
      p.join(projectDir.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: streampath_tool_fixture\n');

    final sourceTools = Directory(p.join(Directory.current.path, 'tools'));
    for (final name in const <String>[
      'build.ps1',
      'package.ps1',
      'cleanup.ps1',
      'run.ps1',
    ]) {
      File(
        p.join(sourceTools.path, name),
      ).copySync(p.join(toolsDir.path, name));
    }

    final fakeUser = Directory(p.join(tempDir.path, 'user'))..createSync();
    final fakeAppData = Directory(p.join(fakeUser.path, 'AppData', 'Roaming'))
      ..createSync(recursive: true);
    final fakeLocalAppData = Directory(
      p.join(fakeUser.path, 'AppData', 'Local'),
    )..createSync(recursive: true);
    final fakeTemp = Directory(p.join(tempDir.path, 'temp'))..createSync();
    isolatedEnvironment = <String, String>{
      ...Platform.environment,
      'USERPROFILE': fakeUser.path,
      'APPDATA': fakeAppData.path,
      'LOCALAPPDATA': fakeLocalAppData.path,
      'TEMP': fakeTemp.path,
      'TMP': fakeTemp.path,
    };
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File fixtureFile(String relativePath, [String contents = 'sentinel']) {
    final file = File(p.join(tempDir.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    return file;
  }

  Future<({int exitCode, String output})> runScript(
    String name, {
    List<String> arguments = const <String>[],
    List<String> inputLines = const <String>[],
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      'powershell.exe',
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        p.join(toolsDir.path, name),
        ...arguments,
      ],
      workingDirectory: tempDir.path,
      environment: environment ?? isolatedEnvironment,
    );
    final stdoutFuture = process.stdout
        .transform(systemEncoding.decoder)
        .join();
    final stderrFuture = process.stderr
        .transform(systemEncoding.decoder)
        .join();
    for (final line in inputLines) {
      process.stdin.writeln(line);
    }
    await process.stdin.close();
    final exitCode = await process.exitCode;
    final output = '${await stdoutFuture}${await stderrFuture}';
    return (exitCode: exitCode, output: output);
  }

  Future<void> createJunction(String link, String target) async {
    final result = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-Command',
      r'& { param($link, $target) New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null }',
      link,
      target,
    ], environment: isolatedEnvironment);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }

  test('build 以真实项目根为边界并拒绝项目内部打包目标', () async {
    final target = Directory(p.join(projectDir.path, 'inside-package'));

    final result = await runScript(
      'build.ps1',
      arguments: <String>['-ValidateTargetOnly', '-Target', target.path],
    );

    expect(result.exitCode, isNot(0), reason: result.output);
    expect(target.existsSync(), isFalse);
  });

  test('build 在项目标记缺失时失败关闭', () async {
    File(p.join(projectDir.path, 'pubspec.yaml')).deleteSync();
    final target = p.join(tempDir.path, 'outside-package');

    final result = await runScript(
      'build.ps1',
      arguments: <String>['-ValidateTargetOnly', '-Target', target],
    );

    expect(result.exitCode, isNot(0), reason: result.output);
    expect(Directory(target).existsSync(), isFalse);
  });

  test('package 的默认目标位于项目目录外且取消时不创建目录', () async {
    final expected = p.join(tempDir.path, 'StreamPath 20260809 V0.1 portable');
    final wrong = p.join(projectDir.path, 'StreamPath 20260809 V0.1 portable');

    final result = await runScript(
      'package.ps1',
      inputLines: const <String>['', 'n'],
    );

    expect(result.exitCode, 0, reason: result.output);
    expect(result.output, contains(expected));
    expect(Directory(expected).existsSync(), isFalse);
    expect(Directory(wrong).existsSync(), isFalse);
  });

  test('run 从真实项目根调用 Flutter', () async {
    final fakeBin = Directory(p.join(tempDir.path, 'fake-bin'))..createSync();
    final cwdFile = File(p.join(tempDir.path, 'flutter-cwd.txt'));
    File(p.join(fakeBin.path, 'flutter.cmd')).writeAsStringSync(
      '@echo off\r\ncd > "%FAKE_FLUTTER_CWD_FILE%"\r\nexit /b 0\r\n',
    );
    final pathKey = isolatedEnvironment.keys.firstWhere(
      (key) => key.toLowerCase() == 'path',
      orElse: () => 'Path',
    );
    final environment = <String, String>{
      ...isolatedEnvironment,
      pathKey:
          '${fakeBin.path}${Platform.isWindows ? ';' : ':'}'
          '${isolatedEnvironment[pathKey] ?? ''}',
      'FAKE_FLUTTER_CWD_FILE': cwdFile.path,
    };

    final result = await runScript(
      'run.ps1',
      inputLines: const <String>['1'],
      environment: environment,
    );

    expect(result.exitCode, 0, reason: result.output);
    expect(cwdFile.readAsStringSync().trim(), projectDir.path);
  });

  test('cleanup 默认只清理项目数据并保留学习数据', () async {
    final expectedRuntime = fixtureFile(
      p.join('project', 'stream_path_data', 'cache', 'mpv.log'),
    );
    final learning = fixtureFile(
      p.join(
        'project',
        'stream_path_data',
        'cache',
        'cache_intelligence_learning.json',
      ),
    );
    final wrongRuntime = fixtureFile(
      p.join('project', 'tools', 'stream_path_data', 'cache', 'mpv.log'),
    );

    final result = await runScript('cleanup.ps1');

    expect(result.exitCode, 0, reason: result.output);
    expect(expectedRuntime.existsSync(), isFalse);
    expect(learning.existsSync(), isTrue);
    expect(wrongRuntime.existsSync(), isTrue);
  });

  test('cleanup 指定测试目录时不扫描隔离环境中的旧用户路径', () async {
    final dataDir = Directory(p.join(tempDir.path, 'explicit-data'));
    final runtime = fixtureFile(p.join('explicit-data', 'cache', 'mpv.log'));
    final learning = fixtureFile(
      p.join('explicit-data', 'cache', 'cache_intelligence_learning.json'),
    );
    final legacy = File(
      p.join(
        isolatedEnvironment['APPDATA']!,
        'com.streampath',
        'streampath',
        'streampath.db',
      ),
    );
    legacy.parent.createSync(recursive: true);
    legacy.writeAsStringSync('legacy-sentinel');

    final result = await runScript(
      'cleanup.ps1',
      arguments: <String>['-DataDir', dataDir.path],
    );

    expect(result.exitCode, 0, reason: result.output);
    expect(runtime.existsSync(), isFalse);
    expect(learning.existsSync(), isTrue);
    expect(legacy.existsSync(), isTrue);
  });

  test('cleanup 拒绝数据目录祖先中的重解析点', () async {
    final realParent = Directory(p.join(tempDir.path, 'real-parent'))
      ..createSync();
    final dataDir = Directory(p.join(realParent.path, 'data'));
    final runtime = fixtureFile(
      p.join('real-parent', 'data', 'cache', 'mpv.log'),
    );
    final junction = p.join(tempDir.path, 'junction-parent');
    await createJunction(junction, realParent.path);

    final result = await runScript(
      'cleanup.ps1',
      arguments: <String>[
        '-DataDir',
        p.join(junction, p.basename(dataDir.path)),
      ],
    );

    expect(result.exitCode, isNot(0), reason: result.output);
    expect(result.output, contains('重解析点'));
    expect(runtime.existsSync(), isTrue);
  });

  test('cleanup 拒绝递归删除包含重解析点的候选目录', () async {
    final dataDir = Directory(p.join(tempDir.path, 'nested-data'))
      ..createSync();
    final candidate = Directory(p.join(dataDir.path, 'directory_cache'))
      ..createSync();
    final external = Directory(p.join(tempDir.path, 'external-cache'))
      ..createSync();
    final sentinel = File(p.join(external.path, 'keep.txt'))
      ..writeAsStringSync('keep');
    await createJunction(
      p.join(candidate.path, 'external-link'),
      external.path,
    );

    final result = await runScript(
      'cleanup.ps1',
      arguments: <String>['-DataDir', dataDir.path],
    );

    expect(result.exitCode, isNot(0), reason: result.output);
    expect(result.output, contains('重解析点'));
    expect(sentinel.existsSync(), isTrue);
  });
}
