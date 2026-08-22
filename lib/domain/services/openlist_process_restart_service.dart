import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// OpenList/AList 进程身份所属的本机监听目标。
class OpenListProcessTargetKey {
  const OpenListProcessTargetKey({
    required this.normalizedOrigin,
    required this.resolvedLocalAddress,
    required this.port,
  });

  final String normalizedOrigin;
  final String resolvedLocalAddress;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is OpenListProcessTargetKey &&
      other.normalizedOrigin == normalizedOrigin &&
      other.resolvedLocalAddress == resolvedLocalAddress &&
      other.port == port;

  @override
  int get hashCode => Object.hash(normalizedOrigin, resolvedLocalAddress, port);
}

/// OpenList/AList 本机进程身份。
class OpenListProcessIdentity {
  const OpenListProcessIdentity({
    required this.target,
    required this.pid,
    required this.parentPid,
    required this.parentName,
    required this.executablePath,
    required this.commandLine,
  });

  final OpenListProcessTargetKey target;
  final int pid;
  final int parentPid;
  final String parentName;
  final String executablePath;
  final String commandLine;

  OpenListProcessIdentity copyWith({int? pid}) => OpenListProcessIdentity(
    target: target,
    pid: pid ?? this.pid,
    parentPid: parentPid,
    parentName: parentName,
    executablePath: executablePath,
    commandLine: commandLine,
  );
}

class OpenListProcessRestartResult {
  const OpenListProcessRestartResult({
    required this.success,
    required this.message,
    this.pid,
  });

  final bool success;
  final String message;
  final int? pid;
}

abstract interface class PlaybackServerRestarter {
  Future<bool> capture(String baseUrl);

  Future<OpenListProcessRestartResult> restart(String baseUrl);
}

typedef OpenListProcessSnapshotLoader =
    Future<OpenListProcessIdentity?> Function(Uri baseUri);
typedef OpenListProcessTargetResolver =
    Future<OpenListProcessTargetKey?> Function(Uri baseUri);
typedef OpenListProcessIdentityValidator =
    Future<bool> Function(OpenListProcessIdentity identity);
typedef OpenListGracefulSignalSender =
    Future<bool> Function(OpenListProcessIdentity identity);
typedef OpenListProcessAliveProbe = Future<bool> Function(int pid);
typedef OpenListProcessLauncher =
    Future<int?> Function(OpenListProcessIdentity identity);
typedef OpenListServerReadyProbe = Future<bool> Function(Uri baseUri);

/// Windows 本机 OpenList/AList 安全重启器。
///
/// 只接管已确认监听目标端口、进程名匹配且以标准
/// `server --force-bin-dir` 运行的实例。关闭阶段向目标控制台发送 Ctrl+C，
/// 等待旧 PID 自然退出；任何身份歧义、共享控制台或超时都直接拒绝，绝不
/// 回退到 taskkill /F。
class OpenListProcessRestartService implements PlaybackServerRestarter {
  OpenListProcessRestartService({
    OpenListProcessSnapshotLoader? snapshotLoader,
    OpenListProcessTargetResolver? targetResolver,
    OpenListProcessIdentityValidator? identityValidator,
    OpenListGracefulSignalSender? signalSender,
    OpenListProcessAliveProbe? aliveProbe,
    OpenListProcessLauncher? launcher,
    OpenListServerReadyProbe? readyProbe,
    this.shutdownTimeout = const Duration(seconds: 15),
    this.readinessTimeout = const Duration(seconds: 30),
    this.pollInterval = const Duration(milliseconds: 500),
  }) : _snapshotLoader = snapshotLoader ?? _loadLocalSnapshot,
       _targetResolver = targetResolver ?? _resolveLocalTarget,
       _identityValidator = identityValidator ?? _validateIdentity,
       _signalSender = signalSender ?? _sendGracefulCtrlC,
       _aliveProbe = aliveProbe ?? _isProcessAlive,
       _launcher = launcher ?? _launchServer,
       _readyProbe = readyProbe ?? _probeServerReady;

  final OpenListProcessSnapshotLoader _snapshotLoader;
  final OpenListProcessTargetResolver _targetResolver;
  final OpenListProcessIdentityValidator _identityValidator;
  final OpenListGracefulSignalSender _signalSender;
  final OpenListProcessAliveProbe _aliveProbe;
  final OpenListProcessLauncher _launcher;
  final OpenListServerReadyProbe _readyProbe;
  final Duration shutdownTimeout;
  final Duration readinessTimeout;
  final Duration pollInterval;

  final Map<OpenListProcessTargetKey, OpenListProcessIdentity> _identities = {};
  final Map<String, int> _captureGenerations = {};
  final Map<String, Future<OpenListProcessRestartResult>> _inflightRestarts =
      {};

  @override
  Future<bool> capture(String baseUrl) async {
    final baseUri = _normalizeBaseUri(baseUrl);
    if (baseUri == null || !Platform.isWindows) return false;
    final origin = _normalizedOrigin(baseUri);
    final generation = (_captureGenerations[origin] ?? 0) + 1;
    _captureGenerations[origin] = generation;
    try {
      final target = await _targetResolver(baseUri);
      final identity = await _snapshotLoader(baseUri);
      if (_captureGenerations[origin] != generation) return false;
      _identities.removeWhere((key, _) => key.normalizedOrigin == origin);
      if (target == null ||
          identity == null ||
          identity.target != target ||
          !_isSupportedIdentity(identity)) {
        return false;
      }
      _identities[target] = identity;
      return true;
    } catch (_) {
      if (_captureGenerations[origin] == generation) {
        _identities.removeWhere((key, _) => key.normalizedOrigin == origin);
      }
      return false;
    }
  }

  @override
  Future<OpenListProcessRestartResult> restart(String baseUrl) async {
    final baseUri = _normalizeBaseUri(baseUrl);
    if (baseUri == null || !Platform.isWindows) {
      return const OpenListProcessRestartResult(
        success: false,
        message: '仅支持安全重启本机 Windows OpenList/AList 进程',
      );
    }
    try {
      final target = await _targetResolver(baseUri);
      if (target == null) {
        return const OpenListProcessRestartResult(
          success: false,
          message: '目标本机地址或监听器存在歧义，已取消重启',
        );
      }
      final restartKey =
          '${target.resolvedLocalAddress.toLowerCase()}:${target.port}';
      final inflight = _inflightRestarts[restartKey];
      if (inflight != null) return await inflight;

      final pending = _restartResolvedTarget(baseUri, target);
      _inflightRestarts[restartKey] = pending;
      try {
        return await pending;
      } finally {
        if (identical(_inflightRestarts[restartKey], pending)) {
          _inflightRestarts.remove(restartKey);
        }
      }
    } catch (_) {
      return const OpenListProcessRestartResult(
        success: false,
        message: 'OpenList/AList 安全重启发生异常，未执行强制结束',
      );
    }
  }

  Future<OpenListProcessRestartResult> _restartResolvedTarget(
    Uri baseUri,
    OpenListProcessTargetKey target,
  ) async {
    final detected = await _snapshotLoader(baseUri);
    if (detected != null) {
      if (detected.target != target || !_isSupportedIdentity(detected)) {
        return const OpenListProcessRestartResult(
          success: false,
          message: 'OpenList/AList 监听目标与进程身份不一致，已取消重启',
        );
      }
      _identities[target] = detected;
    }
    final identity = _identities[target];
    if (identity == null || !_isSupportedIdentity(identity)) {
      return const OpenListProcessRestartResult(
        success: false,
        message: '未记录到可安全重启的本机 OpenList/AList 进程',
      );
    }
    if (!await _identityValidator(identity)) {
      _identities.remove(target);
      return const OpenListProcessRestartResult(
        success: false,
        message: 'OpenList/AList 进程身份已变化，为避免误操作已取消重启',
      );
    }
    if (!await _signalSender(identity)) {
      return const OpenListProcessRestartResult(
        success: false,
        message: '无法安全发送优雅关闭信号，已取消重启且未强制结束进程',
      );
    }
    if (!await _waitUntilStopped(identity.pid)) {
      return const OpenListProcessRestartResult(
        success: false,
        message: 'OpenList/AList 未在安全期限内退出，已取消重启且未强制结束进程',
      );
    }
    final newPid = await _launcher(identity);
    if (newPid == null || newPid <= 0) {
      return const OpenListProcessRestartResult(
        success: false,
        message: 'OpenList/AList 已安全退出，但重新启动失败',
      );
    }
    _identities[target] = identity.copyWith(pid: newPid);
    if (!await _waitUntilReady(baseUri)) {
      return OpenListProcessRestartResult(
        success: false,
        pid: newPid,
        message: 'OpenList/AList 已重新启动，但未在等待期限内恢复服务',
      );
    }
    return OpenListProcessRestartResult(
      success: true,
      pid: newPid,
      message: 'OpenList/AList 已安全重启并恢复服务',
    );
  }

  Future<bool> _waitUntilStopped(int pid) async {
    final deadline = DateTime.now().add(shutdownTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!await _aliveProbe(pid)) return true;
      await Future<void>.delayed(pollInterval);
    }
    return !await _aliveProbe(pid);
  }

  Future<bool> _waitUntilReady(Uri baseUri) async {
    final deadline = DateTime.now().add(readinessTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _readyProbe(baseUri)) return true;
      await Future<void>.delayed(pollInterval);
    }
    return await _readyProbe(baseUri);
  }

  static bool _isSupportedIdentity(OpenListProcessIdentity identity) {
    final name = p.windows.basename(identity.executablePath).toLowerCase();
    if (name != 'openlist.exe' && name != 'alist.exe') return false;
    final parent = identity.parentName.toLowerCase();
    if (parent.isNotEmpty &&
        parent != 'cmd.exe' &&
        parent != 'powershell.exe' &&
        parent != 'pwsh.exe' &&
        parent != 'wscript.exe' &&
        parent != 'streampath.exe' &&
        parent != 'openlist.exe' &&
        parent != 'alist.exe') {
      return false;
    }
    final command = identity.commandLine.trim();
    final executable = identity.executablePath;
    final quotedPrefix = '"$executable"';
    String remainder;
    if (command.toLowerCase().startsWith(quotedPrefix.toLowerCase())) {
      remainder = command.substring(quotedPrefix.length).trim();
    } else if (command.toLowerCase().startsWith(executable.toLowerCase())) {
      remainder = command.substring(executable.length).trim();
    } else {
      return false;
    }
    final args = remainder.split(RegExp(r'\s+'));
    return args.length == 2 &&
        args[0].toLowerCase() == 'server' &&
        args[1].toLowerCase() == '--force-bin-dir';
  }

  static Uri? _normalizeBaseUri(String value) {
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty) {
      return null;
    }
    final segments = parsed.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty &&
        (segments.last.toLowerCase() == 'dav' ||
            segments.last.toLowerCase() == 'api')) {
      segments.removeLast();
    }
    return parsed.replace(
      path: segments.isEmpty ? '' : '/${segments.join('/')}',
      query: null,
      fragment: null,
    );
  }

  static int _effectivePort(Uri uri) =>
      uri.hasPort ? uri.port : (uri.scheme.toLowerCase() == 'https' ? 443 : 80);

  static String _normalizedOrigin(Uri uri) => Uri(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    port: _effectivePort(uri),
  ).origin;

  static String _canonicalAddress(String value) {
    final parsed = InternetAddress.tryParse(value.trim());
    return (parsed?.address ?? value.trim()).toLowerCase();
  }

  static Future<OpenListProcessTargetKey?> _resolveLocalTarget(
    Uri baseUri,
  ) async {
    final literal = InternetAddress.tryParse(baseUri.host);
    final resolved = literal == null
        ? await InternetAddress.lookup(
            baseUri.host,
          ).timeout(const Duration(seconds: 2))
        : <InternetAddress>[literal];
    final interfaces = await NetworkInterface.list(
      includeLoopback: true,
    ).timeout(const Duration(seconds: 2));
    final localAddresses = {
      for (final interface in interfaces)
        for (final address in interface.addresses)
          _canonicalAddress(address.address),
    };
    final candidates = <String>{};
    for (final address in resolved) {
      final normalized = _canonicalAddress(address.address);
      if (address.isLoopback || localAddresses.contains(normalized)) {
        candidates.add(normalized);
      }
    }
    if (candidates.length != 1) return null;
    return OpenListProcessTargetKey(
      normalizedOrigin: _normalizedOrigin(baseUri),
      resolvedLocalAddress: candidates.single,
      port: _effectivePort(baseUri),
    );
  }

  static Future<OpenListProcessIdentity?> _loadLocalSnapshot(
    Uri baseUri,
  ) async {
    final target = await _resolveLocalTarget(baseUri);
    if (target == null) return null;
    return _loadSnapshotForTarget(target);
  }

  static Future<OpenListProcessIdentity?> _loadSnapshotForTarget(
    OpenListProcessTargetKey target,
  ) async {
    final script =
        '''
\$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new()
\$items=@(Get-NetTCPConnection -State Listen -LocalPort ${target.port} -ErrorAction SilentlyContinue | ForEach-Object {
    \$listener=\$_
    \$proc=Get-CimInstance Win32_Process -Filter "ProcessId = \$(\$listener.OwningProcess)" -ErrorAction SilentlyContinue
    \$parent=if(\$null -eq \$proc){\$null}else{Get-CimInstance Win32_Process -Filter "ProcessId = \$(\$proc.ParentProcessId)" -ErrorAction SilentlyContinue}
    [PSCustomObject]@{
      LocalAddress=\$listener.LocalAddress
      OwningProcess=\$listener.OwningProcess
      ProcessId=if(\$null -eq \$proc){0}else{\$proc.ProcessId}
      ParentProcessId=if(\$null -eq \$proc){0}else{\$proc.ParentProcessId}
      ParentName=if(\$null -eq \$parent){''}else{\$parent.Name}
      ExecutablePath=if(\$null -eq \$proc){''}else{\$proc.ExecutablePath}
      CommandLine=if(\$null -eq \$proc){''}else{\$proc.CommandLine}
    }
  })
if(\$items.Count -eq 0){ '[]' } else { \$items | ConvertTo-Json -Compress }
''';
    final result = await _runPowerShell(script);
    if (result.exitCode != 0 || result.stdout.toString().trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(result.stdout.toString().trim());
    final items = decoded is List ? decoded : [decoded];
    final owners = <int>{};
    final candidates = <String, OpenListProcessIdentity>{};
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final listenerAddress = item['LocalAddress']?.toString() ?? '';
      if (!_listenerAccepts(target.resolvedLocalAddress, listenerAddress)) {
        continue;
      }
      final owner = (item['OwningProcess'] as num?)?.toInt();
      if (owner == null || owner <= 0) return null;
      owners.add(owner);
      final identity = _identityFromJson(item, target);
      if (identity == null || !_isSupportedIdentity(identity)) continue;
      final fingerprint = <Object>[
        identity.pid,
        identity.executablePath.toLowerCase(),
        identity.commandLine,
      ].join('|');
      candidates[fingerprint] = identity;
    }
    if (owners.length != 1 || candidates.length != 1) return null;
    final identity = candidates.values.single;
    return identity.pid == owners.single ? identity : null;
  }

  static bool _listenerAccepts(String targetAddress, String listenerAddress) {
    final target = _canonicalAddress(targetAddress);
    final listener = _canonicalAddress(listenerAddress);
    return listener == target || listener == '0.0.0.0' || listener == '::';
  }

  static Future<bool> _validateIdentity(
    OpenListProcessIdentity identity,
  ) async {
    final current = await _loadSnapshotForTarget(identity.target);
    return current != null &&
        current.target == identity.target &&
        current.pid == identity.pid &&
        current.parentPid == identity.parentPid &&
        current.parentName.toLowerCase() == identity.parentName.toLowerCase() &&
        current.executablePath.toLowerCase() ==
            identity.executablePath.toLowerCase() &&
        current.commandLine == identity.commandLine &&
        _isSupportedIdentity(current);
  }

  static Future<bool> _sendGracefulCtrlC(
    OpenListProcessIdentity identity,
  ) async {
    final script =
        '''
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class StreamPathConsoleSignal {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint processId);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern uint GetConsoleProcessList(uint[] processList, uint processCount);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);
}
"@
[StreamPathConsoleSignal]::FreeConsole() | Out-Null
if(-not [StreamPathConsoleSignal]::AttachConsole(${identity.pid})){ exit 11 }
\$ids=New-Object uint32[] 16
\$count=[StreamPathConsoleSignal]::GetConsoleProcessList(\$ids, \$ids.Length)
if(\$count -eq 0 -or \$count -gt \$ids.Length){ [StreamPathConsoleSignal]::FreeConsole() | Out-Null; exit 12 }
\$allowed=@(${identity.pid},${identity.parentPid},\$PID)
for(\$i=0; \$i -lt \$count; \$i++){
  if(\$allowed -notcontains [int]\$ids[\$i]){ [StreamPathConsoleSignal]::FreeConsole() | Out-Null; exit 13 }
}
[StreamPathConsoleSignal]::SetConsoleCtrlHandler([IntPtr]::Zero, \$true) | Out-Null
\$sent=[StreamPathConsoleSignal]::GenerateConsoleCtrlEvent(0, 0)
Start-Sleep -Milliseconds 250
[StreamPathConsoleSignal]::FreeConsole() | Out-Null
if(-not \$sent){ exit 14 }
''';
    final result = await _runPowerShell(script);
    return result.exitCode == 0;
  }

  static Future<bool> _isProcessAlive(int pid) async {
    final result = await Process.run('tasklist', [
      '/FI',
      'PID eq $pid',
      '/NH',
      '/FO',
      'CSV',
    ]);
    if (result.exitCode != 0) return false;
    for (final line in result.stdout.toString().split(RegExp(r'[\r\n]+'))) {
      final match = RegExp(r'^"[^"]*","(\d+)"').firstMatch(line.trim());
      if (match != null && int.tryParse(match.group(1)!) == pid) return true;
    }
    return false;
  }

  static Future<int?> _launchServer(OpenListProcessIdentity identity) async {
    final executable = File(identity.executablePath);
    if (!await executable.exists()) return null;
    final escapedExecutable = executable.path.replaceAll("'", "''");
    final escapedDirectory = p.windows
        .dirname(executable.path)
        .replaceAll("'", "''");
    final script =
        '''
\$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new()
\$process=Start-Process -FilePath '$escapedExecutable' -ArgumentList @('server','--force-bin-dir') -WorkingDirectory '$escapedDirectory' -WindowStyle Hidden -PassThru
\$process.Id
''';
    final result = await _runPowerShell(script);
    if (result.exitCode != 0) return null;
    return int.tryParse(
      result.stdout.toString().trim().split('\n').last.trim(),
    );
  }

  static Future<bool> _probeServerReady(Uri baseUri) async {
    final prefix = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    final uri = baseUri.replace(
      path: '$prefix/api/public/settings',
      query: null,
      fragment: null,
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>().timeout(const Duration(seconds: 2));
      return response.statusCode >= 200 && response.statusCode < 500;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static OpenListProcessIdentity? _identityFromJson(
    Object? value,
    OpenListProcessTargetKey target,
  ) {
    if (value is! Map<String, dynamic>) return null;
    final pid = (value['ProcessId'] as num?)?.toInt();
    final executablePath = value['ExecutablePath']?.toString() ?? '';
    final commandLine = value['CommandLine']?.toString() ?? '';
    if (pid == null ||
        pid <= 0 ||
        executablePath.isEmpty ||
        commandLine.isEmpty) {
      return null;
    }
    return OpenListProcessIdentity(
      target: target,
      pid: pid,
      parentPid: (value['ParentProcessId'] as num?)?.toInt() ?? 0,
      parentName: value['ParentName']?.toString() ?? '',
      executablePath: executablePath,
      commandLine: commandLine,
    );
  }

  static Future<ProcessResult> _runPowerShell(String script) => Process.run(
    'powershell.exe',
    [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
}
