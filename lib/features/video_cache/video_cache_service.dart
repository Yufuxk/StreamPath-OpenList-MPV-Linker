import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseException;
import '../../core/utils/app_paths.dart';
import '../../core/errors/app_exception.dart';
import '../../data/models/film_catalog_item.dart';
import 'video_cache_models.dart';
import 'video_cache_worker.dart';
import 'video_cache_disk.dart';

typedef VideoCacheTransferResolver =
    Future<Map<String, dynamic>> Function(
      String source,
      String path,
      bool strm,
    );

class VideoCacheService {
  VideoCacheService._(this.resolveTransfer, this._configFile);
  final VideoCacheTransferResolver resolveTransfer;
  final File _configFile;
  final changes = ValueNotifier<int>(0);
  final files = <String, VideoCacheFile>{};
  final bundles = <String, Map<String, dynamic>>{};
  final _pending = <int, Completer<Object?>>{};
  late Isolate _isolate;
  late ReceivePort _output;
  late SendPort _input;
  late StreamSubscription<dynamic> _subscription;
  int _sequence = 0;
  bool _closed = false;
  VideoCacheException? _workerFailure;
  bool playbackSuspended = true;
  String? directory;
  late String defaultDirectory;
  String get targetDirectory => directory ?? defaultDirectory;

  static Future<VideoCacheService> open({
    required VideoCacheTransferResolver resolveTransfer,
    Directory? dataDirectory,
    Map<String, dynamic> Function(String)? diskSpaceProvider,
  }) async {
    final root = dataDirectory ?? await AppPaths.dataDirectory();
    final config = File(p.join(root.path, 'config', 'video_cache.json'));
    final service = VideoCacheService._(resolveTransfer, config);
    service.defaultDirectory = p.join(root.path, 'video_cache');
    if (await config.exists()) {
      final value = jsonDecode(await config.readAsString()) as Map;
      service.directory = value['directory'] as String?;
    }
    await Directory(service.defaultDirectory).create(recursive: true);
    await Directory(p.join(root.path, 'library')).create(recursive: true);
    service._output = ReceivePort();
    final ready = Completer<SendPort>();
    service._subscription = service._output.listen((message) {
      if (message == null ||
          message is List &&
              message.length == 2 &&
              message.first is String &&
              message[1] is String) {
        const failure = VideoCacheException('缓存下载服务意外停止');
        service._workerFailure = failure;
        if (!ready.isCompleted) ready.completeError(failure);
        for (final task in service._pending.values) {
          task.completeError(failure);
        }
        service._pending.clear();
        if (!service._closed) service.changes.value++;
        return;
      }
      final row = message as List;
      switch (row[0]) {
        case 'ready':
          ready.complete(row[1] as SendPort);
        case 'response':
          final completion = service._pending.remove(row[1]);
          if (row[3] != null) {
            completion?.completeError(VideoCacheException(row[3] as String));
          } else {
            completion?.complete(row[2]);
          }
        case 'resolve':
          final data = Map<String, dynamic>.from(row[2] as Map);
          unawaited(() async {
            try {
              final result = await resolveTransfer(
                data['source'] as String,
                data['path'] as String,
                data['strm'] as bool,
              );
              service._input.send([row[1], 'resolved', result]);
            } on VideoCacheException catch (error) {
              service._input.send([
                row[1],
                'resolved',
                {'error': error.message},
              ]);
            } on AppException {
              service._input.send([
                row[1],
                'resolved',
                {'error': '缓存来源不可用'},
              ]);
            } on FilmCatalogException {
              service._input.send([
                row[1],
                'resolved',
                {'error': '缓存来源不可用'},
              ]);
            } on FileSystemException {
              service._input.send([
                row[1],
                'resolved',
                {'error': '缓存来源不可用'},
              ]);
            } on DatabaseException {
              service._input.send([
                row[1],
                'resolved',
                {'error': '视频缓存操作失败'},
              ]);
            }
          }());
        case 'file':
          final file = VideoCacheFile(Map<String, dynamic>.from(row[1] as Map));
          service.files[file.id] = file;
          service.changes.value++;
        case 'all':
          service._replace(Map<String, dynamic>.from(row[1] as Map));
      }
    });
    service._isolate = await Isolate.spawn(
      videoCacheWorker,
      [service._output.sendPort, diskSpaceProvider ?? videoCacheDisk],
      onError: service._output.sendPort,
      onExit: service._output.sendPort,
    );
    try {
      service._input = await ready.future;
      final initial = await service._request('open', {
        'database': p.join(root.path, 'library', 'video_cache.db'),
      });
      service._replace(Map<String, dynamic>.from(initial as Map));
    } catch (_) {
      await service._subscription.cancel();
      service._output.close();
      service._isolate.kill();
      service.changes.dispose();
      rethrow;
    }
    return service;
  }

  void _replace(Map<String, dynamic> data) {
    files.clear();
    bundles.clear();
    for (final value in data['files'] as List) {
      final file = VideoCacheFile(Map<String, dynamic>.from(value as Map));
      files[file.id] = file;
    }
    for (final value in data['bundles'] as List) {
      final bundle = Map<String, dynamic>.from(value as Map);
      bundles[bundle['id'] as String] = bundle;
    }
    changes.value++;
  }

  Future<Object?> _request(String operation, Map<String, dynamic> data) {
    if (_closed) throw StateError('Video cache service is closed');
    if (_workerFailure != null) throw _workerFailure!;
    final id = ++_sequence;
    final completion = Completer<Object?>();
    _pending[id] = completion;
    _input.send([id, operation, data]);
    return completion.future;
  }

  Future<void> saveDirectory(String? value) async {
    if (value != null &&
        (!p.isAbsolute(value) || !await Directory(value).exists())) {
      throw const VideoCacheException('缓存目录不存在');
    }
    await _configFile.parent.create(recursive: true);
    final temporary = File('${_configFile.path}.partial');
    await temporary.writeAsString(
      jsonEncode({'version': 1, 'directory': value}),
      flush: true,
    );
    await temporary.rename(_configFile.path);
    directory = value;
    changes.value++;
  }

  Future<Map<String, dynamic>> probe(
    String source,
    String path, {
    bool strm = false,
  }) async {
    final transfer = await resolveTransfer(source, path, strm);
    return {
      ...Map<String, dynamic>.from(
        await _request('probe', {'transfer': transfer, 'path': path}) as Map,
      ),
      'progress': transfer['progress'],
    };
  }

  Future<void> enqueue(List<VideoCachePlan> plans) async {
    await _request('enqueue', {
      'files': {
        for (final plan in plans)
          for (final file in plan.files) file.id: file.data,
      }.values.toList(),
      'bundles': plans.map((plan) => plan.bundle).toList(),
    });
  }

  Future<void> checkSpace(List<VideoCachePlan> plans) async {
    await _request('checkSpace', {
      'files': {
        for (final plan in plans)
          for (final f in plan.files) f.id: f.data,
      }.values.toList(),
    });
  }

  Future<void> setPlaybackSuspended(bool value) async {
    if (playbackSuspended == value) return;
    playbackSuspended = value;
    changes.value++;
    await _request('suspend', {'value': value});
  }

  Future<void> pause(String id) async {
    await _request('pause', {'id': id});
  }

  Future<void> resume(String id) async {
    await _request('resume', {'id': id});
  }

  Future<void> cancel(String id) async {
    await _request('cancel', {'id': id});
  }

  Future<void> delete(
    String id, {
    Set<String> protectedPaths = const {},
  }) async {
    await _request('delete', {'id': id, 'protected': protectedPaths.toList()});
  }

  bool get hasPending => files.values.any((file) => file.pending);
  bool complete(Map<String, dynamic> bundle) =>
      (bundle['files'] as List).every((id) => files[id]?.complete == true);
  bool hasSource(String source) =>
      bundles.values.any((b) => b['source'] == source && complete(b));

  String? progressTargetFor(String source, String physicalPath) {
    final uri = Uri.tryParse(physicalPath);
    final path = uri?.scheme == 'file' ? uri!.toFilePath() : physicalPath;
    for (final bundle in bundles.values) {
      if (bundle['source'] == source &&
          p.equals(files[bundle['main']]?.destination ?? '', path)) {
        return bundle['progress'] as String;
      }
    }
    return null;
  }

  Future<CachedPlaybackTarget?> lookup(
    String source,
    String path, {
    String? identity,
  }) async {
    final candidates = bundles.values.where(
      (b) =>
          b['source'] == source &&
          b['path'] == path &&
          (identity == null || b['identity'] == identity) &&
          complete(b),
    );
    for (final bundle in candidates) {
      var valid = true;
      final selected = <String, VideoCacheFile>{};
      for (final id in (bundle['files'] as List).cast<String>()) {
        final file = files[id]!;
        final local = File(file.destination);
        try {
          if (!await local.exists() || await local.length() != file.size) {
            valid = false;
            break;
          }
        } on FileSystemException {
          valid = false;
          break;
        }
        selected[id] = file;
      }
      if (valid) return CachedPlaybackTarget(bundle, selected);
    }
    return null;
  }

  Future<String?> localFile(
    String source,
    String path, {
    String? identity,
  }) async {
    final eligible = {
      for (final bundle in bundles.values.where(
        (b) =>
            b['source'] == source &&
            (identity == null || b['identity'] == identity) &&
            complete(b),
      ))
        ...(bundle['files'] as List).cast<String>(),
    };
    for (final file in files.values.where(
      (f) =>
          f.sourceId == source &&
          f.path == path &&
          f.complete &&
          eligible.contains(f.id),
    )) {
      final local = File(file.destination);
      if (await local.exists() && await local.length() == file.size) {
        return local.path;
      }
    }
    return null;
  }

  List<Map<String, dynamic>>? directorySnapshot(
    String source,
    String path, {
    String? identity,
  }) {
    for (final bundle in bundles.values.where(
      (b) =>
          b['source'] == source &&
          (identity == null || b['identity'] == identity) &&
          complete(b),
    )) {
      final snapshots = bundle['directories'] as Map;
      if (snapshots[path] case final List entries) {
        return entries
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
      }
    }
    return null;
  }

  Future<void> close() async {
    if (_closed) return;
    if (_workerFailure == null) await _request('close', {});
    _closed = true;
    for (final task in _pending.values) {
      task.completeError(const VideoCacheException('缓存下载已暂停'));
    }
    _pending.clear();
    await _subscription.cancel();
    _output.close();
    _isolate.kill();
    changes.dispose();
  }
}
