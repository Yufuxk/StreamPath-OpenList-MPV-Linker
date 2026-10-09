import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class AppReleaseVersion implements Comparable<AppReleaseVersion> {
  const AppReleaseVersion(this.major, this.minor, this.patch, this.build);
  final int major, minor, patch, build;

  static AppReleaseVersion parse(String source, {int? build}) {
    final match = RegExp(
      r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\.(0|[1-9]\d*))?(?:\+(0|[1-9]\d*))?$',
    ).firstMatch(source);
    if (match == null) throw const FormatException('Invalid release version');
    final values = [
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3] ?? '0'),
      build ?? int.parse(match[4] ?? '0'),
    ];
    if (values.any((value) => value < 0 || value > 65535)) {
      throw const FormatException('Release version is out of range');
    }
    return AppReleaseVersion(values[0], values[1], values[2], values[3]);
  }

  @override
  int compareTo(AppReleaseVersion other) {
    final mine = [major, minor, patch, build];
    final theirs = [other.major, other.minor, other.patch, other.build];
    for (var i = 0; i < mine.length; i++) {
      final result = mine[i].compareTo(theirs[i]);
      if (result != 0) return result;
    }
    return 0;
  }

  @override
  String toString() => '$major.$minor.$patch+$build';
}

enum AppUpdateStatus {
  idle,
  checking,
  downloading,
  ready,
  installing,
  current,
  unavailable,
  failed,
}

class AppUpdateAsset {
  const AppUpdateAsset({
    required this.version,
    required this.name,
    required this.uri,
    required this.size,
    required this.hash,
    required this.kind,
  });
  final AppReleaseVersion version;
  final String name, hash, kind;
  final Uri uri;
  final int size;

  static AppUpdateAsset fromRelease(
    Map<String, dynamic> release,
    Map<String, dynamic> metadata,
    String kind,
  ) {
    if (release['draft'] != false ||
        release['prerelease'] != false ||
        metadata['schema'] != 1) {
      throw const FormatException('Unsupported release');
    }
    final version = AppReleaseVersion.parse(
      metadata['version'] as String,
      build: metadata['build'] as int,
    );
    if (version.build < 1) throw const FormatException('Missing build number');
    final tag = AppReleaseVersion.parse(release['tag_name'] as String);
    if (tag.major != version.major ||
        tag.minor != version.minor ||
        tag.patch != version.patch) {
      throw const FormatException('Release tag and metadata disagree');
    }
    final candidates = (metadata['assets'] as List)
        .cast<Map<String, dynamic>>()
        .where((row) => row['kind'] == kind && row['platform'] == 'windows-x64')
        .toList();
    if (candidates.length != 1) {
      throw const FormatException('Matching release asset is missing');
    }
    final selected = candidates.single;
    final name = selected['name'] as String;
    final display = metadata['displayVersion'] as String;
    final displayVersion = AppReleaseVersion.parse(display);
    if (displayVersion.major != version.major ||
        displayVersion.minor != version.minor ||
        displayVersion.patch != version.patch) {
      throw const FormatException('Invalid display version');
    }
    final date = metadata['date'] as String;
    if (!RegExp(r'^\d{8}$').hasMatch(date) ||
        name !=
            'StreamPath.$date.V$display.${kind == 'installed' ? 'setup.exe' : 'portable.zip'}') {
      throw const FormatException('Invalid release asset name');
    }
    final apiAssets = (release['assets'] as List)
        .cast<Map<String, dynamic>>()
        .where((row) => row['name'] == name)
        .toList();
    if (apiAssets.length != 1) {
      throw const FormatException('Release asset is missing');
    }
    final apiAsset = apiAssets.single;
    final hash = selected['sha256'] as String;
    final size = selected['size'] as int;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        size <= 0 ||
        size > 1024 * 1024 * 1024 ||
        apiAsset['size'] != size) {
      throw const FormatException('Invalid asset integrity metadata');
    }
    final digest = apiAsset['digest'];
    if (digest != null && digest != 'sha256:$hash') {
      throw const FormatException('GitHub digest disagrees');
    }
    final uri = trustedAssetUri(
      apiAsset['browser_download_url'] as String,
      release['tag_name'] as String,
      name,
    );
    return AppUpdateAsset(
      version: version,
      name: name,
      uri: uri,
      size: size,
      hash: hash,
      kind: kind,
    );
  }

  static Uri trustedAssetUri(String url, String tag, String name) {
    final uri = Uri.parse(url);
    final expected = [
      'Yufuxk',
      'StreamPath-OpenList-MPV-Linker',
      'releases',
      'download',
      tag,
      name,
    ];
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.port != 443 ||
        !listEquals(uri.pathSegments, expected)) {
      throw const FormatException(
        'Release URL is outside the configured repository',
      );
    }
    return uri;
  }
}

/// 更新只写暂存目录，关闭与文件替换分别交给原关闭路径和独立 helper。
class AppUpdateService extends ChangeNotifier {
  AppUpdateService({
    required this.appDirectory,
    required this.version,
    required this.installed,
    Dio? client,
    this.downloadDirectory,
  }) : _client =
           client ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(seconds: 60),
               headers: {
                 'User-Agent': 'StreamPath-Updater',
                 'Accept': 'application/vnd.github+json',
               },
             ),
           );

  static const repository = 'Yufuxk/StreamPath-OpenList-MPV-Linker';
  final Directory appDirectory;
  final AppReleaseVersion version;
  final bool installed;
  final Directory? downloadDirectory;
  final Dio _client;
  final CancelToken _cancel = CancelToken();
  AppUpdateStatus status = AppUpdateStatus.idle;
  AppUpdateAsset? asset;
  File? package;
  double progress = 0;
  bool previousUpdateFailed = false;
  File? _closeCommit;
  bool _disposed = false;
  String get kind => installed ? 'installed' : 'portable';
  bool get busy =>
      status == AppUpdateStatus.checking ||
      status == AppUpdateStatus.downloading ||
      status == AppUpdateStatus.installing;

  void _setStatus(AppUpdateStatus value) {
    status = value;
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    final result = File(
      p.join(appDirectory.path, '.streampath-update-result.json'),
    );
    try {
      if (await result.exists()) {
        previousUpdateFailed =
            (jsonDecode(await result.readAsString())
                as Map<String, dynamic>)['success'] ==
            false;
      }
    } on FileSystemException {
      _setStatus(AppUpdateStatus.failed);
      return;
    } on FormatException {
      previousUpdateFailed = true;
    } on TypeError {
      previousUpdateFailed = true;
    }
    if (!kReleaseMode ||
        !Platform.isWindows ||
        !await File(
          p.join(appDirectory.path, 'streampath-release.json'),
        ).exists()) {
      return;
    }
    await check();
  }

  Future<void> check() async {
    if (busy || _disposed) return;
    _setStatus(AppUpdateStatus.checking);
    try {
      final response = await _client.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$repository/releases/latest',
        cancelToken: _cancel,
      );
      final release = response.data!;
      if (release['draft'] != false || release['prerelease'] != false) {
        throw const FormatException('Not a stable release');
      }
      final metadataAssets = (release['assets'] as List)
          .cast<Map<String, dynamic>>()
          .where((row) => row['name'] == 'StreamPath.release.json')
          .toList();
      if (metadataAssets.length != 1) {
        final latest = AppReleaseVersion.parse(release['tag_name'] as String);
        _setStatus(
          latest.compareTo(version) > 0
              ? AppUpdateStatus.unavailable
              : AppUpdateStatus.current,
        );
        return;
      }
      final row = metadataAssets.single;
      if (row['size'] is! int || row['size'] > 128 * 1024) {
        throw const FormatException('Release metadata is too large');
      }
      final uri = AppUpdateAsset.trustedAssetUri(
        row['browser_download_url'] as String,
        release['tag_name'] as String,
        'StreamPath.release.json',
      );
      final metadataResponse = await _client.get<String>(
        uri.toString(),
        options: Options(responseType: ResponseType.plain),
        cancelToken: _cancel,
      );
      final raw = metadataResponse.data!;
      if (utf8.encode(raw).length > 128 * 1024) {
        throw const FormatException('Release metadata is too large');
      }
      final metadata = jsonDecode(raw) as Map<String, dynamic>;
      final latest = AppReleaseVersion.parse(
        metadata['version'] as String,
        build: metadata['build'] as int,
      );
      if (latest.compareTo(version) <= 0) {
        _setStatus(
          package != null ? AppUpdateStatus.ready : AppUpdateStatus.current,
        );
        return;
      }
      final selected = AppUpdateAsset.fromRelease(release, metadata, kind);
      await _download(selected);
    } on DioException {
      if (!_disposed) {
        _setStatus(
          package != null ? AppUpdateStatus.ready : AppUpdateStatus.failed,
        );
      }
    } on FormatException {
      _setStatus(AppUpdateStatus.unavailable);
    } on TypeError {
      // GitHub 与发布元数据都是外部输入。
      _setStatus(AppUpdateStatus.unavailable);
    } on FileSystemException {
      _setStatus(AppUpdateStatus.failed);
    }
  }

  Future<void> _download(AppUpdateAsset selected) async {
    if (package != null &&
        asset?.hash == selected.hash &&
        await package!.exists()) {
      _setStatus(AppUpdateStatus.ready);
      return;
    }
    package = null;
    asset = selected;
    progress = 0;
    _setStatus(AppUpdateStatus.downloading);
    final root =
        downloadDirectory ??
        Directory(
          p.join(
            Platform.environment['LOCALAPPDATA']!,
            'StreamPath',
            'updates',
          ),
        );
    await root.create(recursive: true);
    final directory = Directory(p.join(root.path, 'release-${selected.hash}'));
    await directory.create(recursive: true);
    final cached = File(p.join(directory.path, selected.name));
    if (await cached.exists()) {
      if (await cached.length() == selected.size &&
          (await sha256.bind(cached.openRead()).first).toString() ==
              selected.hash) {
        package = cached;
        progress = 1;
        _setStatus(AppUpdateStatus.ready);
        return;
      }
      await cached.delete();
    }
    final partial = File(p.join(directory.path, '${selected.name}.partial'));
    try {
      final response = await _client.get<ResponseBody>(
        selected.uri.toString(),
        options: Options(responseType: ResponseType.stream),
        cancelToken: _cancel,
      );
      final sink = partial.openWrite();
      var received = 0;
      try {
        await for (final bytes in response.data!.stream) {
          received += bytes.length;
          if (received > selected.size) {
            throw const FormatException('Downloaded asset is too large');
          }
          sink.add(bytes);
          final next = received / selected.size;
          if (next - progress >= 0.01) {
            progress = next;
            if (!_disposed) notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      if (received != selected.size) {
        throw const FormatException('Downloaded asset is truncated');
      }
      final hash = await sha256.bind(partial.openRead()).first;
      if (hash.toString() != selected.hash) {
        throw const FormatException('Downloaded asset digest failed');
      }
      package = await partial.rename(cached.path);
      progress = 1;
      _setStatus(AppUpdateStatus.ready);
    } finally {
      if (package == null) {
        await directory.delete(recursive: true);
      }
    }
  }

  Future<void> restartToUpdate({
    required Future<bool> Function() busyWithUserData,
  }) async {
    if (status != AppUpdateStatus.ready || package == null || asset == null) {
      return;
    }
    if (await busyWithUserData()) throw const AppUpdateBlocked();
    if (!await File(
      p.join(appDirectory.path, 'streampath-release.json'),
    ).exists()) {
      throw const FileSystemException('Current program manifest is missing');
    }
    final helper = File(p.join(appDirectory.path, 'streampath-updater.ps1'));
    // 把 helper 放在下载目录，程序替换不会影响当前执行的脚本。
    final copiedHelper = await helper.copy(
      p.join(package!.parent.path, 'helper.ps1'),
    );
    final ready = File(p.join(package!.parent.path, 'helper-ready'));
    if (await ready.exists()) await ready.delete();
    final commit = File(p.join(package!.parent.path, 'helper-commit'));
    if (await commit.exists()) await commit.delete();
    _closeCommit = commit;
    final powershell = p.join(
      Platform.environment['SystemRoot']!,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    _setStatus(AppUpdateStatus.installing);
    try {
      await Process.start(powershell, [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        copiedHelper.path,
        '-Target',
        appDirectory.path,
        '-Package',
        package!.path,
        '-Kind',
        kind,
        '-ExpectedSha256',
        asset!.hash,
        '-ExpectedVersion',
        '${asset!.version}',
        '-ParentPid',
        '$pid',
        '-ReadyFile',
        ready.path,
        '-CommitFile',
        commit.path,
      ], mode: ProcessStartMode.detached);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await ready.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          throw const ProcessException(
            'powershell.exe',
            [],
            'Update helper did not become ready',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await const MethodChannel(
        'streampath/appearance',
      ).invokeMethod<void>('close');
    } on ProcessException {
      await cancelRestart();
      rethrow;
    } on PlatformException {
      await cancelRestart();
      rethrow;
    }
  }

  Future<void> confirmClosePrepared() =>
      _closeCommit!.writeAsString('prepared');

  Future<void> cancelRestart() async {
    final commit = _closeCommit;
    if (commit != null && await commit.exists()) await commit.delete();
    _closeCommit = null;
    _setStatus(AppUpdateStatus.ready);
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel.cancel('Updater disposed');
    _client.close(force: true);
    super.dispose();
  }
}

class AppUpdateBlocked implements Exception {
  const AppUpdateBlocked();
}
