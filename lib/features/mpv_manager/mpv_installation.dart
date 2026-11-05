import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../data/models/player_config.dart';
import '../../data/models/playback_media_info.dart';
import '../../domain/services/mpv_session_controller.dart';
import 'mpv_document.dart';
import 'mpv_script_schema.dart';

class MpvManagedFile {
  const MpvManagedFile(
    this.path,
    this.kind,
    this.origin, {
    this.active = true,
    this.exists = true,
  });
  final String path, origin;
  final MpvDocumentKind kind;
  final bool active;
  final bool exists;
}

class MpvLocalScript {
  const MpvLocalScript(
    this.path,
    this.source,
    this.automatic,
    this.explicit,
    this.configPath, {
    this.schema,
  });
  final String path;
  final String? source, configPath;
  final bool automatic, explicit;
  final MpvScriptSchema? schema;
  bool get disabled => path.toLowerCase().endsWith('.disable');
}

class MpvInstallationContext {
  const MpvInstallationContext(
    this.executable,
    this.roots,
    this.files,
    this.scripts,
    this.shaders,
    this.configDisabled,
    this.diagnostics,
  );
  final String executable;
  final List<String> roots, shaders, diagnostics;
  final List<MpvManagedFile> files;
  final List<MpvLocalScript> scripts;
  final bool configDisabled;
}

class MpvOptionInfo {
  const MpvOptionInfo(
    this.name,
    this.type,
    this.defaultValue,
    this.minimum,
    this.maximum,
    this.choices,
  );
  factory MpvOptionInfo.fromJson(Map data) => MpvOptionInfo(
    data['name'] as String,
    data['type'] as String,
    data['default-value'],
    data['min'] as num?,
    data['max'] as num?,
    (data['choices'] as List?)?.map((e) => '$e').toList() ?? const [],
  );
  final String name, type;
  final Object? defaultValue;
  final num? minimum, maximum;
  final List<String> choices;
  String? validate(String value) {
    if (type == 'Flag' && value != 'yes' && value != 'no') return 'boolean';
    if (type == 'Integer' ||
        type == 'Integer64' ||
        type == 'Float' ||
        type == 'Double') {
      final number = num.tryParse(value);
      if (number == null ||
          !number.isFinite ||
          (type.startsWith('Integer') && number != number.truncateToDouble()) ||
          minimum != null && number < minimum! ||
          maximum != null && number > maximum!) {
        return 'number';
      }
    }
    if (type == 'Choices' && choices.isNotEmpty && !choices.contains(value)) {
      return 'choice';
    }
    return null;
  }
}

class MpvCapabilities {
  const MpvCapabilities(
    this.version,
    this.optionNames,
    this.options,
    this.commands,
    this.keys,
  );
  final String version;
  final List<String> optionNames, commands, keys;
  final Map<String, MpvOptionInfo> options;
}

/// 探测进程只服务于管理器，关闭页面不会触碰播放会话。
class MpvCapabilityProbe {
  Process? _process;
  Process? _keyProcess;
  MpvSessionController? _ipc;
  bool _closed = false;

  Future<MpvCapabilities> read(String executable, Set<String> requested) async {
    final pipe =
        r'\\.\pipe\streampath-mpv-manager-'
        '${pid}_${DateTime.now().microsecondsSinceEpoch}';
    try {
      if (_closed) throw const MpvManagerException('cancelled');
      final process = await Process.start(executable, [
        '--no-config',
        '--load-scripts=no',
        '--osc=no',
        '--ytdl=no',
        '--idle=yes',
        '--vo=null',
        '--ao=null',
        '--input-terminal=no',
        '--terminal=no',
        '--input-ipc-server=$pipe',
      ]);
      _process = process;
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      if (_closed) {
        process.kill();
        throw const MpvManagerException('cancelled');
      }
      final ipc = MpvSessionController(pipeName: pipe);
      _ipc = ipc;
      if (!await ipc.connect(timeout: const Duration(seconds: 5))) {
        throw const MpvManagerException('probe');
      }
      final version = await ipc.getProperty('mpv-version') as String;
      final names = (await ipc.getProperty('options') as List).cast<String>();
      final commands = (await ipc.getProperty('command-list') as List)
          .map((e) => (e as Map)['name'] as String)
          .toList();
      final options = <String, MpvOptionInfo>{};
      for (final name in requested.intersection(names.toSet())) {
        if (_closed) throw const MpvManagerException('cancelled');
        final info = await ipc.getProperty('option-info/$name');
        if (info is Map) options[name] = MpvOptionInfo.fromJson(info);
      }
      // CLI 按键列表不读取任何用户配置。
      final keyProcess = await Process.start(executable, [
        '--no-config',
        '--load-scripts=no',
        '--input-keylist',
      ]);
      _keyProcess = keyProcess;
      final keyOutput = keyProcess.stdout.transform(utf8.decoder).join();
      unawaited(keyProcess.stderr.drain<void>());
      try {
        await keyProcess.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        keyProcess.kill();
        rethrow;
      }
      final keys = await keyOutput;
      _keyProcess = null;
      return MpvCapabilities(
        version,
        names,
        options,
        commands,
        keys.split(RegExp(r'\r?\n')).where((e) => e.isNotEmpty).toList(),
      );
    } on StateError catch (error) {
      throw MpvManagerException('probe', '$error');
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    _closed = true;
    final keyProcess = _keyProcess;
    if (keyProcess != null) {
      keyProcess.kill();
      await keyProcess.exitCode;
      _keyProcess = null;
    }
    final process = _process;
    if (process != null) {
      process.kill();
      await process.exitCode;
      _process = null;
    }
    await _ipc?.dispose();
    _ipc = null;
  }
}

Future<String> resolveMpvExecutable(String value) async {
  String path;
  if (value.contains('/') || value.contains(r'\')) {
    path = p.absolute(value);
  } else {
    final found = await Process.run(
      Platform.isWindows ? 'where.exe' : 'which',
      [value],
    ).timeout(const Duration(seconds: 3));
    if (found.exitCode != 0) throw const MpvManagerException('executable');
    path = '${found.stdout}'.split(RegExp(r'\r?\n')).first.trim();
  }
  if (!File(path).existsSync()) throw const MpvManagerException('executable');
  if (p.extension(path).toLowerCase() == '.com') {
    final exe = p.setExtension(path, '.exe');
    if (File(exe).existsSync()) path = exe;
  }
  if (!p.basenameWithoutExtension(path).toLowerCase().contains('mpv')) {
    throw const MpvManagerException('executable');
  }
  return File(path).resolveSymbolicLinks();
}

Future<MpvInstallationContext> discoverMpv(
  PlayerConfig player, {
  String? browseRoot,
  PlaybackMediaInfo? mediaInfo,
}) async {
  final executable = await resolveMpvExecutable(player.executable);
  final args = player.argsFor(mediaInfo);
  return Isolate.run(() => _discover(executable, args, browseRoot));
}

MpvInstallationContext _discover(
  String executable,
  List<String> args,
  String? browseRoot,
) {
  final exeDir = p.dirname(executable);
  final diagnostics = <String>[];
  String? forced, input;
  var disabled = false;
  var autoScripts = true;
  bool? autoScriptsOverride;
  for (final argument in args) {
    if (argument.startsWith('--config-dir=')) forced = argument.substring(13);
    if (argument.startsWith('--input-conf=')) input = argument.substring(13);
    if (argument == '--no-config' || argument == '--config=no') disabled = true;
    if (argument == '--config=yes') disabled = false;
    if (argument == '--no-load-scripts' || argument == '--load-scripts=no') {
      autoScriptsOverride = false;
    }
    if (argument == '--load-scripts=yes') autoScriptsOverride = true;
  }
  final environment = Platform.environment;
  final roots = <String>[];
  if (browseRoot != null) {
    roots.add(p.absolute(browseRoot));
  } else if (forced != null && forced.isNotEmpty) {
    roots.add(p.absolute(forced));
  } else if ((environment['MPV_HOME'] ?? '').isNotEmpty) {
    roots.add(p.absolute(environment['MPV_HOME']!));
  } else if (Directory(p.join(exeDir, 'portable_config')).existsSync()) {
    roots.add(p.join(exeDir, 'portable_config'));
  } else {
    if (Platform.isWindows) {
      roots.add(p.join(environment['APPDATA']!, 'mpv'));
      roots.add(exeDir);
      roots.add(p.join(exeDir, 'mpv'));
    } else {
      roots.add(
        p.join(
          environment['XDG_CONFIG_HOME'] ??
              p.join(environment['HOME']!, '.config'),
          'mpv',
        ),
      );
    }
  }
  final files = <MpvManagedFile>[];
  final visited = <String>{};
  final explicit = <String>{}, shaders = <String>{};
  String? expand(String value) {
    if (value.isEmpty || value.contains('://') || value.contains('\n')) {
      return null;
    }
    if (value.startsWith('~~/')) {
      final rest = value.substring(3);
      for (final root in roots) {
        final candidate = p.join(root, rest);
        if (FileSystemEntity.typeSync(candidate) !=
            FileSystemEntityType.notFound) {
          return p.normalize(candidate);
        }
      }
      return p.normalize(p.join(roots.first, rest));
    }
    if (value.startsWith('~~home/')) {
      return p.normalize(p.join(roots.first, value.substring(7)));
    }
    if (value.startsWith('~~exe_dir/')) {
      return p.normalize(p.join(exeDir, value.substring(10)));
    }
    if (value.startsWith('~/')) {
      return p.normalize(
        p.join(
          environment['USERPROFILE'] ?? environment['HOME']!,
          value.substring(2),
        ),
      );
    }
    return p.normalize(p.absolute(value));
  }

  void reference(String key, String value) {
    if (key == 'script' || key == 'scripts' || key == 'scripts-append') {
      for (final item
          in key == 'script' || key.endsWith('-append')
              ? [value]
              : splitMpvPaths(value)) {
        final path = expand(item);
        if (path != null) explicit.add(path);
      }
    }
    if (key == 'glsl-shader' ||
        key == 'glsl-shaders' ||
        key == 'glsl-shaders-append') {
      for (final item
          in key == 'glsl-shader' || key.endsWith('-append')
              ? [value]
              : splitMpvPaths(value)) {
        final path = expand(item);
        if (path != null) shaders.add(path);
      }
    }
  }

  void add(String path, MpvDocumentKind kind, String origin, {int depth = 0}) {
    final file = File(path);
    if (Directory(path).existsSync()) {
      diagnostics.add('notFile');
      return;
    }
    final canonical = file.existsSync()
        ? file.resolveSymbolicLinksSync()
        : p.absolute(path);
    if (!visited.add(
      Platform.isWindows ? canonical.toLowerCase() : canonical,
    )) {
      return;
    }
    files.add(
      MpvManagedFile(
        canonical,
        kind,
        origin,
        active: file.existsSync() && !disabled && browseRoot == null,
        exists: file.existsSync(),
      ),
    );
    if (!file.existsSync() || kind != MpvDocumentKind.options) return;
    final document = MpvDocumentSnapshot.parse(
      canonical,
      file.readAsBytesSync(),
      kind,
    );
    for (final line in document.entries.where((l) => l.enabled)) {
      reference(line.key, line.value);
      if (line.scope.isEmpty || line.scope == 'default') {
        if (line.key == 'load-scripts') autoScripts = line.value != 'no';
        if (line.key == 'no-load-scripts') autoScripts = false;
      }
      if (line.key == 'input-conf' &&
          (line.scope.isEmpty || line.scope == 'default')) {
        input = line.value;
      }
      if (line.key == 'include') {
        final include = expand(line.value);
        if (include == null) {
          diagnostics.add('localOnly');
          continue;
        }
        if (depth >= 20) {
          diagnostics.add('includeDepth');
          continue;
        }
        add(include, MpvDocumentKind.options, 'include', depth: depth + 1);
      }
    }
  }

  for (final root in roots.reversed) {
    final config = p.join(root, 'mpv.conf');
    if (File(config).existsSync() || root == roots.first) {
      add(config, MpvDocumentKind.options, 'mpv.conf');
    }
  }
  // 命令行 input-conf 的优先级高于文件内声明。
  for (final argument in args) {
    if (argument.startsWith('--input-conf=')) input = argument.substring(13);
    final match = RegExp(r'^--([^=]+)=(.*)$').firstMatch(argument);
    if (match != null) reference(match[1]!, match[2]!);
  }
  final inputPath = input != null
      ? expand(input!)
      : roots
            .map((r) => p.join(r, 'input.conf'))
            .firstWhere(
              (f) => File(f).existsSync(),
              orElse: () => p.join(roots.first, 'input.conf'),
            );
  if (inputPath != null) add(inputPath, MpvDocumentKind.input, 'input.conf');
  final scripts = <String, bool>{};
  for (final root in roots) {
    final dir = Directory(p.join(root, 'scripts'));
    if (dir.existsSync()) {
      for (final entity in dir.listSync(followLinks: false)) {
        final path = entity.path;
        final original = path.toLowerCase().endsWith('.disable')
            ? path.substring(0, path.length - 8)
            : path;
        if (['.lua', '.js'].contains(p.extension(original).toLowerCase()) ||
            File(p.join(path, 'main.lua')).existsSync() ||
            File(p.join(path, 'main.js')).existsSync()) {
          scripts[p.normalize(path)] = true;
        }
      }
    }
    final opts = Directory(p.join(root, 'script-opts'));
    if (opts.existsSync()) {
      for (final file in opts.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.conf'),
      )) {
        add(file.path, MpvDocumentKind.scriptOptions, 'script-opts');
      }
    }
    final shaderDir = Directory(p.join(root, 'shaders'));
    if (shaderDir.existsSync()) {
      for (final file
          in shaderDir
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((f) => f.path.endsWith('.glsl'))) {
        shaders.add(file.path);
      }
    }
  }
  for (final path in explicit) {
    scripts.putIfAbsent(path, () => false);
  }
  final scriptList = <MpvLocalScript>[];
  for (final entry in scripts.entries) {
    final path = entry.key;
    String? source;
    if (File(path).existsSync()) {
      source = path;
    } else {
      for (final main in ['main.lua', 'main.js']) {
        if (File(p.join(path, main)).existsSync()) {
          source = p.join(path, main);
          break;
        }
      }
    }
    String? conf;
    MpvScriptSchema? schema;
    if (source != null) {
      String? content;
      try {
        content = File(source).readAsStringSync();
      } on FormatException {
        diagnostics.add('encoding');
      }
      schema = content == null ? null : verifiedScriptSchema(content);
      final originalPath = path.toLowerCase().endsWith('.disable')
          ? path.substring(0, path.length - 8)
          : path;
      final identifier = content == null
          ? null
          : scriptOptionsIdentifier(
              content,
              p
                  .basenameWithoutExtension(originalPath)
                  .replaceAll(RegExp('[^a-zA-Z0-9]'), '_'),
            );
      if (identifier != null) {
        for (final root in roots) {
          final candidate = p.join(root, 'script-opts', '$identifier.conf');
          if (File(candidate).existsSync()) {
            conf = candidate;
            break;
          }
        }
        if (conf != null) {
          add(conf, MpvDocumentKind.scriptOptions, 'script-opts');
        }
      }
    }
    scriptList.add(
      MpvLocalScript(
        path,
        source,
        entry.value,
        explicit.any((e) => p.equals(e, path)),
        conf,
        schema: schema,
      ),
    );
  }
  if (disabled || !(autoScriptsOverride ?? autoScripts)) {
    diagnostics.add('noAutoScripts');
  }
  return MpvInstallationContext(
    executable,
    roots,
    files,
    scriptList,
    shaders.where((path) => File(path).existsSync()).toList()..sort(),
    disabled,
    diagnostics,
  );
}

List<String> splitMpvPathTokens(String value) {
  if (value.isEmpty) return [];
  final separator = Platform.isWindows ? ';' : ':';
  final result = <String>[];
  var start = 0;
  for (var i = 0; i < value.length; i++) {
    if (value[i] == separator && (i == 0 || value[i - 1] != r'\')) {
      result.add(value.substring(start, i));
      start = i + 1;
    }
  }
  result.add(value.substring(start));
  return result;
}

/// 只识别静态调用参数；注释、字符串中的示例与动态表达式不作为配置来源。
String? scriptOptionsIdentifier(String source, String defaultName) {
  final tokens = <String>[];
  for (var i = 0; i < source.length;) {
    if (source.startsWith('--', i) || source.startsWith('//', i)) {
      final long = RegExp(r'--\[(=*)\[').matchAsPrefix(source, i);
      final end = long == null
          ? source.indexOf('\n', i)
          : source.indexOf(']${long[1]}]', long.end);
      i = end < 0
          ? source.length
          : end + (long == null ? 1 : long[1]!.length + 2);
      continue;
    }
    if (source.startsWith('/*', i)) {
      final end = source.indexOf('*/', i + 2);
      i = end < 0 ? source.length : end + 2;
      continue;
    }
    final long = RegExp(r'\[(=*)\[').matchAsPrefix(source, i);
    if (long != null) {
      final end = source.indexOf(']${long[1]}]', long.end);
      tokens.add('string');
      i = end < 0 ? source.length : end + long[1]!.length + 2;
      continue;
    }
    final token = RegExp(
      r'''(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|[A-Za-z_]\w*|\S)''',
    ).matchAsPrefix(source, i);
    if (token == null) {
      i++;
      continue;
    }
    tokens.add(token[0]!);
    i = token.end;
  }
  for (var i = 0; i + 3 < tokens.length; i++) {
    if (tokens[i] != 'read_options' ||
        tokens[i + 1] != '(' ||
        !RegExp(r'^\w+$').hasMatch(tokens[i + 2])) {
      continue;
    }
    if (tokens[i + 3] == ')') return defaultName;
    if (tokens[i + 3] != ',' ||
        i + 5 >= tokens.length ||
        ![',', ')'].contains(tokens[i + 5])) {
      continue;
    }
    final name = tokens[i + 4];
    if (name == 'nil' || name == '_') return defaultName;
    if (RegExp(r'''^["'][A-Za-z0-9_-]+["']$''').hasMatch(name)) {
      return name.substring(1, name.length - 1);
    }
  }
  return null;
}

List<String> splitMpvPaths(String value) => splitMpvPathTokens(value)
    .map(
      (part) => part.replaceAll(
        Platform.isWindows ? r'\;' : r'\:',
        Platform.isWindows ? ';' : ':',
      ),
    )
    .toList();
