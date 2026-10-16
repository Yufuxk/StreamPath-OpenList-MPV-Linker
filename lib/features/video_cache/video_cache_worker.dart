import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/media_connection.dart';
import '../../domain/services/native_storage_reader.dart';
import 'video_cache_models.dart';

void videoCacheWorker(List<Object> setup) {
  final input = ReceivePort();
  final worker = _CacheWorker(
    setup[0] as SendPort,
    setup[1] as Map<String, dynamic> Function(String),
  );
  input.listen((message) => worker.command(message as List));
  worker.output.send(['ready', input.sendPort]);
}

class _TransferControl {
  bool stopped = false;
  String stopState = 'queued';
  final stoppedSignal = Completer<void>();
  HttpClient? http;
  NativeStorageReader? native;
  Future<void>? future;
  void stop() {
    stopped = true;
    if (!stoppedSignal.isCompleted) stoppedSignal.complete();
    http?.close(force: true);
    native?.cancelCurrent();
  }
}

class _CacheWorker {
  _CacheWorker(this.output, this.disk);
  final SendPort output;
  final Map<String, dynamic> Function(String) disk;
  late Database db;
  final files = <String, Map<String, dynamic>>{};
  final bundles = <String, Map<String, dynamic>>{};
  final active = <String, _TransferControl>{};
  final probeControls = <_TransferControl>{};
  final resolutions = <int, Completer<Map<String, dynamic>>>{};
  int sequence = 0;
  bool suspended = true, closing = false;
  bool indexFailed = false;
  static const indexError = '缓存索引写入失败，请释放空间并重新启动软件';
  Future<void> mutations = Future.value();
  static const margin = 256 * 1024 * 1024;

  void command(List message) {
    final id = message[0] as int, operation = message[1] as String;
    final data = Map<String, dynamic>.from(message[2] as Map);
    if (operation == 'resolved') {
      final completion = resolutions.remove(id);
      if (data['error'] != null) {
        completion?.completeError(VideoCacheException(data['error'] as String));
      } else {
        completion?.complete(data);
      }
      return;
    }
    Future<Object?> action() => handle(operation, data);
    final Future<Object?> task;
    if (operation == 'probe') {
      task = action();
    } else {
      task = mutations.then((_) => action());
      mutations = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    }
    unawaited(
      task.then(
        (result) {
          output.send(['response', id, result, null]);
        },
        onError: (Object error, StackTrace stack) {
          if (error is VideoCacheException ||
              error is FileSystemException ||
              error is SocketException ||
              error is TimeoutException ||
              error is HttpException ||
              error is DatabaseException ||
              error is FilmCatalogException) {
            output.send([
              'response',
              id,
              null,
              error is VideoCacheException
                  ? error.message
                  : error is FileSystemException
                  ? '缓存文件读写失败，请检查目录权限和磁盘空间'
                  : '视频缓存操作失败',
            ]);
          } else {
            Error.throwWithStackTrace(error, stack);
          }
        },
      ),
    );
  }

  Future<Map<String, dynamic>> resolve(Map<String, dynamic> file) {
    final id = ++sequence;
    final completion = Completer<Map<String, dynamic>>();
    resolutions[id] = completion;
    output.send([
      'resolve',
      id,
      {
        'source': file['source'],
        'path': file['path'],
        'strm': file['strm'] ?? false,
      },
    ]);
    return completion.future;
  }

  Future<Object?> handle(String operation, Map<String, dynamic> data) async {
    if (indexFailed && !['close', 'probe', 'checkSpace'].contains(operation)) {
      throw const VideoCacheException(indexError);
    }
    switch (operation) {
      case 'open':
        sqfliteFfiInit();
        db = await databaseFactoryFfi.openDatabase(
          data['database'] as String,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) async {
              await db.execute(
                'CREATE TABLE files(id TEXT PRIMARY KEY, data TEXT NOT NULL)',
              );
              await db.execute(
                'CREATE TABLE bundles(id TEXT PRIMARY KEY, data TEXT NOT NULL)',
              );
            },
          ),
        );
        for (final table in ['files', 'bundles']) {
          for (final row in await db.query(table)) {
            final value = Map<String, dynamic>.from(
              jsonDecode(row['data'] as String) as Map,
            );
            (table == 'files' ? files : bundles)[row['id'] as String] = value;
          }
        }
        for (final file in files.values) {
          if (file['state'] == 'finalizing') {
            final target = File(file['destination'] as String);
            file['state'] =
                await target.exists() && await target.length() == file['size']
                ? 'completed'
                : 'queued';
            await save(file);
          } else if ([
            'downloading',
            'waiting',
            'pausedPlayback',
          ].contains(file['state'])) {
            file['state'] = 'queued';
            file['received'] = file['committed'];
            file['speed'] = 0;
            await save(file);
          }
        }
        return {
          'files': files.values.toList(),
          'bundles': bundles.values.toList(),
        };
      case 'probe':
        final descriptor = Map<String, dynamic>.from(data['transfer'] as Map);
        final control = _TransferControl();
        probeControls.add(control);
        final task = probe(descriptor, data['path'] as String, control);
        control.future = task.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
        return task;
      case 'enqueue':
        final incoming = (data['files'] as List)
            .map((f) => Map<String, dynamic>.from(f as Map))
            .toList();
        final incomingBundles = (data['bundles'] as List)
            .map((b) => Map<String, dynamic>.from(b as Map))
            .toList();
        final revived = <String>{};
        for (final file in incoming) {
          final old = files[file['id']];
          if (old?['state'] == 'completed' &&
              !await File(old!['destination'] as String).exists()) {
            revived.add(file['id'] as String);
            file.addAll({
              'state': 'queued',
              'committed': 0,
              'received': 0,
              'speed': 0.0,
            });
          }
        }
        await space(incoming);
        await db.transaction((txn) async {
          for (final file in incoming) {
            final old = files[file['id']];
            if (old != null) {
              if (old['version'] != file['version'] ||
                  old['size'] != file['size']) {
                throw const VideoCacheException('缓存源文件已变更，请先删除旧缓存');
              }
              if (!revived.contains(file['id'])) continue;
            }
            file.addAll({
              'state': 'queued',
              'received': 0,
              'committed': 0,
              'speed': 0.0,
            });
            await txn.insert('files', {
              'id': file['id'],
              'data': jsonEncode(file),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
          for (final bundle in incomingBundles) {
            await txn.insert('bundles', {
              'id': bundle['id'],
              'data': jsonEncode(bundle),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        });
        for (final file in incoming) {
          if (revived.contains(file['id'])) files[file['id'] as String] = file;
          files.putIfAbsent(file['id'] as String, () => file);
        }
        for (final bundle in incomingBundles) {
          bundles[bundle['id'] as String] = bundle;
        }
        publishAll();
        schedule();
        return null;
      case 'suspend':
        suspended = data['value'] as bool;
        if (suspended) {
          final running = active.values.toList();
          for (final control in running) {
            control.stop();
          }
          await Future.wait([for (final control in running) control.future!]);
        } else {
          schedule();
        }
        return null;
      case 'pause':
      case 'resume':
      case 'cancel':
        final selectedBundle = bundles[data['id']];
        if (selectedBundle != null) {
          selectedBundle['state'] = operation == 'resume'
              ? 'queued'
              : operation == 'cancel'
              ? 'cancelled'
              : 'paused';
          await db.update(
            'bundles',
            {'data': jsonEncode(selectedBundle)},
            where: 'id=?',
            whereArgs: [data['id']],
          );
        }
        final ids = ((bundles[data['id']]?['files'] as List?) ?? [data['id']])
            .cast<String>();
        for (final id in ids) {
          if (operation != 'resume' &&
              selectedBundle != null &&
              bundles.values.any(
                (b) =>
                    b['id'] != selectedBundle['id'] &&
                    !['paused', 'cancelled'].contains(b['state']) &&
                    (b['files'] as List).contains(id),
              )) {
            continue;
          }
          final file = files[id];
          if (file == null || file['state'] == 'completed') continue;
          final control = active[id];
          if (control != null) {
            control.stopState = operation == 'cancel'
                ? 'cancelled'
                : operation == 'pause'
                ? 'paused'
                : 'queued';
            control.stop();
            await control.future;
          }
          file['state'] = operation == 'resume'
              ? 'queued'
              : operation == 'cancel'
              ? 'cancelled'
              : 'paused';
          file['error'] = null;
          file['speed'] = 0.0;
          await save(file);
          publish(file);
        }
        publishAll();
        schedule();
        return null;
      case 'delete':
        final bundle = bundles[data['id']];
        if (bundle == null) return null;
        final ids = (bundle['files'] as List).cast<String>();
        final protected = (data['protected'] as List).cast<String>().toSet();
        if (ids.any(
          (id) => protected.any(
            (path) =>
                path == files[id]?['destination'] ||
                p.isWithin(path, files[id]!['destination'] as String),
          ),
        )) {
          throw const VideoCacheException('缓存正在播放，请关闭播放器后再删除');
        }
        for (final id in ids) {
          if (bundles.values.any(
            (b) => b['id'] != bundle['id'] && (b['files'] as List).contains(id),
          )) {
            continue;
          }
          final control = active[id];
          if (control != null) {
            control.stopState = 'cancelled';
            control.stop();
            await control.future;
          }
          final file = files[id]!;
          await validateDestination(file);
          for (final suffix in ['', '.partial']) {
            final target = File('${file['destination']}$suffix');
            if (await target.exists()) await target.delete();
          }
          await db.delete('files', where: 'id=?', whereArgs: [id]);
          files.remove(id);
        }
        await db.delete('bundles', where: 'id=?', whereArgs: [bundle['id']]);
        bundles.remove(bundle['id']);
        publishAll();
        schedule();
        return null;
      case 'checkSpace':
        await space(
          (data['files'] as List)
              .map((f) => Map<String, dynamic>.from(f as Map))
              .toList(),
        );
        return null;
      case 'close':
        closing = true;
        suspended = true;
        final running = {...active.values, ...probeControls}.toList();
        for (final control in running) {
          control.stop();
        }
        await Future.wait([for (final control in running) control.future!]);
        await db.close();
        return null;
      default:
        throw StateError('Unknown cache command: $operation');
    }
  }

  Future<Map<String, dynamic>> probe(
    Map<String, dynamic> descriptor,
    String path,
    _TransferControl control,
  ) async {
    try {
      return await metadata(descriptor, path, control);
    } finally {
      control.http?.close(force: true);
      await control.native?.close();
      probeControls.remove(control);
    }
  }

  Future<void> validateDestination(Map<String, dynamic> file) async {
    final root = Directory(file['root'] as String);
    final resolved = await root.resolveSymbolicLinks();
    final destination = file['destination'] as String;
    if (!p.isWithin(root.path, destination)) {
      throw const VideoCacheException('缓存文件路径无效');
    }
    final parent = Directory(p.dirname(destination));
    await parent.create(recursive: true);
    if (!p.isWithin(resolved, await parent.resolveSymbolicLinks())) {
      throw const VideoCacheException('缓存文件路径无效');
    }
    if (await FileSystemEntity.type(destination, followLinks: false) ==
            FileSystemEntityType.link ||
        await FileSystemEntity.type(
              '$destination.partial',
              followLinks: false,
            ) ==
            FileSystemEntityType.link) {
      throw const VideoCacheException('缓存文件路径无效');
    }
  }

  Future<void> space(List<Map<String, dynamic>> incoming) async {
    final destinations = <String, String>{};
    for (final file in [...files.values, ...incoming]) {
      for (final suffix in ['', '.partial']) {
        final path = p.normalize('${file['destination']}$suffix').toLowerCase();
        final owner = destinations[path];
        if (owner != null && owner != file['id']) {
          throw const VideoCacheException('缓存目标存在重名文件，请更换目录或版本');
        }
        destinations[path] = file['id'] as String;
      }
    }
    for (final file in incoming) {
      if (!files.containsKey(file['id']) &&
          (await File(file['destination'] as String).exists() ||
              await File('${file['destination']}.partial').exists())) {
        throw const VideoCacheException('缓存目标文件已存在，请先删除旧缓存');
      }
    }
    final disks = <String, Map<String, dynamic>>{};
    final needed = <String, int>{};
    final roots = <String, Map<String, dynamic>>{};
    final merged = <String, Map<String, dynamic>>{
      for (final f in files.values.where(
        (f) => [
          'queued',
          'downloading',
          'waiting',
          'pausedPlayback',
          'paused',
        ].contains(f['state']),
      ))
        f['id'] as String: f,
      for (final f in incoming) f['id'] as String: files[f['id']] ?? f,
    };
    for (final file in merged.values) {
      if (file['state'] == 'completed' &&
          await File(file['destination'] as String).exists()) {
        if (await File(file['destination'] as String).length() !=
            file['size']) {
          throw const VideoCacheException('缓存成品已失效，请删除后重新缓存');
        }
        continue;
      }
      final root = Directory(file['root'] as String);
      if (!roots.containsKey(root.path)) {
        if (!await root.exists()) throw const VideoCacheException('缓存目录不存在');
        roots[root.path] = disk(root.path);
      }
      final information = roots[root.path]!;
      final volume = information['volume'] as String;
      disks[volume] = information;
      if (information['fat32'] == true && (file['size'] as int) > 0xffffffff) {
        throw const VideoCacheException('目标磁盘不支持超过 4 GiB 的单个文件');
      }
      needed[volume] =
          (needed[volume] ?? 0) +
          max(
            0,
            (file['size'] as int) -
                (file['state'] == 'completed'
                    ? 0
                    : file['received'] as int? ?? 0),
          );
    }
    for (final entry in needed.entries) {
      if ((disks[entry.key]!['available'] as int) < entry.value + margin) {
        throw VideoCacheException(
          '缓存磁盘空间不足|${entry.value + margin}|${disks[entry.key]!['available']}',
        );
      }
    }
    for (final root in incoming.map((f) => f['root'] as String).toSet()) {
      final probe = File(
        p.join(
          root,
          '.streampath-write-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await probe.writeAsBytes(const [], flush: true);
      await probe.delete();
    }
  }

  Future<void> save(Map<String, dynamic> file) => db.update(
    'files',
    {
      'data': jsonEncode({...file, 'speed': 0.0}),
    },
    where: 'id=?',
    whereArgs: [file['id']],
  );
  void publish(Map<String, dynamic> file) =>
      output.send(['file', Map<String, dynamic>.of(file)]);
  void publishAll() => output.send([
    'all',
    {'files': files.values.toList(), 'bundles': bundles.values.toList()},
  ]);

  void schedule() {
    if (suspended || closing || indexFailed) return;
    for (final file in files.values.where((f) => f['state'] == 'queued')) {
      if (active.length >= 2) break;
      final id = file['id'] as String;
      if (active.containsKey(id)) continue;
      final control = _TransferControl();
      active[id] = control;
      control.future = run(file, control).whenComplete(() {
        active.remove(id);
        schedule();
      });
    }
  }

  Future<void> run(Map<String, dynamic> file, _TransferControl control) async {
    try {
      for (var attempt = 0; ; attempt++) {
        if (control.stopped) break;
        file['state'] = 'downloading';
        file['error'] = null;
        publish(file);
        try {
          await transfer(file, control);
          break;
        } on SocketException {
          if (!await retry(file, control, attempt)) rethrow;
        } on TimeoutException {
          if (!await retry(file, control, attempt)) rethrow;
        } on HttpException {
          if (!await retry(file, control, attempt)) rethrow;
        } on VideoCacheException catch (error) {
          if (!(error.transient || error.refreshTransfer && attempt == 0) ||
              !await retry(file, control, attempt)) {
            rethrow;
          }
        } on FilmCatalogException catch (error) {
          if (error.code != 'sourceReadFailed' ||
              !await retry(file, control, attempt)) {
            rethrow;
          }
        }
      }
      if (control.stopped && file['state'] != 'completed') {
        file['state'] = 'queued';
      }
    } on DatabaseException {
      stopForIndexFailure();
    } on VideoCacheException catch (error) {
      file['state'] = control.stopped ? control.stopState : 'failed';
      file['error'] = error.message;
    } on FileSystemException {
      file['state'] = control.stopped ? control.stopState : 'failed';
      file['error'] = '缓存文件读写失败，请检查目录权限和磁盘空间';
    } on SocketException {
      file['state'] = control.stopped ? control.stopState : 'failed';
      file['error'] = '缓存网络连接失败';
    } on HttpException {
      file['state'] = control.stopped ? control.stopState : 'failed';
      file['error'] = '缓存网络连接失败';
    } on TimeoutException {
      file['state'] = control.stopped ? control.stopState : 'failed';
      file['error'] = '缓存网络连接超时';
    } on FilmCatalogException {
      file['state'] = control.stopped ? control.stopState : 'failed';
      file['error'] = '缓存来源读取失败';
    } finally {
      control.http?.close(force: true);
      await control.native?.close();
      if (indexFailed) {
        file['state'] = 'failed';
        file['error'] = indexError;
      }
      if (control.stopped && file['state'] != 'completed') {
        file['state'] = control.stopState;
      }
      file['speed'] = 0.0;
      if (!indexFailed) {
        try {
          await save(file);
        } on DatabaseException {
          stopForIndexFailure();
          file['state'] = 'failed';
          file['error'] = indexError;
        }
      }
      publish(file);
    }
  }

  void stopForIndexFailure() {
    indexFailed = true;
    for (final control in active.values) {
      control.stopState = 'failed';
      control.stop();
    }
  }

  Future<bool> retry(
    Map<String, dynamic> file,
    _TransferControl control,
    int attempt,
  ) async {
    if (control.stopped) return false;
    if (attempt >= 6) return false;
    file['state'] = 'waiting';
    file['speed'] = 0.0;
    publish(file);
    await Future.any([
      Future<void>.delayed(Duration(seconds: [1, 2, 4, 8, 16, 30][attempt])),
      control.stoppedSignal.future,
    ]);
    return !control.stopped;
  }

  Future<Map<String, dynamic>> metadata(
    Map<String, dynamic> descriptor,
    String path,
    _TransferControl control,
  ) async {
    if (descriptor['kind'] == 'native') {
      final reader = control.native ??= await NativeStorageReader.open(
        MediaConnection.fromJson(
          Map<String, dynamic>.from(descriptor['config'] as Map),
        ),
        descriptor['password'] as String,
        libraryPath: descriptor['library'] as String?,
      );
      final nativePath = descriptor['nativePath'] as String? ?? path;
      final stat = await reader.stat(nativePath);
      final version =
          stat['version'] ??
          ((stat['modified'] as int? ?? 0) > 0
              ? '${stat['size']}:${stat['modified']}'
              : null);
      if (stat['directory'] == true || version == null) {
        throw const VideoCacheException('缓存源不支持安全断点续传');
      }
      if ((stat['size'] as int) > 0) {
        await reader.openStream(nativePath, (stat['size'] as int) > 1 ? 1 : 0);
        await reader.readStream(1);
        await reader.closeStream();
      }
      return {
        'size': stat['size'],
        'version': version,
        'validator': 'native',
        'identity': descriptor['identity'],
      };
    }
    final response = await http(descriptor, control, 'bytes=0-0');
    try {
      if (response.statusCode == 416 &&
              response.headers.value('content-range') == 'bytes */0' ||
          response.statusCode == 200 && response.contentLength == 0) {
        await response.drain<void>();
        return {
          'size': 0,
          'version': 'empty:0',
          'validator': 'empty',
          'identity': descriptor['identity'],
        };
      }
      final range = RegExp(
        r'^bytes 0-0/(\d+)$',
      ).firstMatch(response.headers.value('content-range') ?? '');
      if (response.statusCode != 206 ||
          range == null ||
          ![
            null,
            'identity',
          ].contains(response.headers.value('content-encoding'))) {
        throw const VideoCacheException('缓存源不支持安全断点续传');
      }
      final tag = response.headers.value('etag');
      String? version, validator;
      if (tag != null && RegExp(r'^"[^"\r\n]*"$').hasMatch(tag)) {
        version = tag;
        validator = 'etag';
      } else if (tag == null) {
        final modified = response.headers.value('last-modified');
        final date = response.headers.value('date');
        if (modified != null && date != null) {
          try {
            if (HttpDate.parse(
                  date,
                ).difference(HttpDate.parse(modified)).inSeconds >=
                60) {
              version = modified;
              validator = 'last-modified';
            }
          } on HttpException {
            /* 无有效版本时拒绝安全续传。 */
          }
        }
      }
      if (version == null) throw const VideoCacheException('缓存源不支持安全断点续传');
      var count = 0;
      await for (final bytes in response.timeout(const Duration(seconds: 30))) {
        count += bytes.length;
        if (count > 1) throw const VideoCacheException('缓存响应范围无效');
      }
      if (count != 1) throw const VideoCacheException('缓存响应范围无效');
      return {
        'size': int.parse(range[1]!),
        'version': version,
        'validator': validator,
        'identity': descriptor['identity'],
      };
    } finally {
      control.http?.close(force: true);
      control.http = null;
    }
  }

  Future<HttpClientResponse> http(
    Map<String, dynamic> descriptor,
    _TransferControl control,
    String range, {
    String? version,
  }) async {
    final client = control.http ??= HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 15);
    var url = Uri.parse(descriptor['url'] as String);
    final origin = Uri.parse(descriptor['origin'] as String);
    for (var redirects = 0; ; redirects++) {
      if (control.stopped) throw const VideoCacheException('缓存下载已暂停');
      if (!['http', 'https'].contains(url.scheme)) {
        throw const VideoCacheException('缓存源不支持安全断点续传');
      }
      final request = await client
          .getUrl(url)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set('Accept-Encoding', 'identity');
      request.headers.set('Range', range);
      if (version != null) request.headers.set('If-Range', version);
      if (url.scheme == origin.scheme &&
          url.host == origin.host &&
          url.port == origin.port) {
        for (final entry in Map<String, dynamic>.from(
          descriptor['headers'] as Map,
        ).entries) {
          request.headers.set(entry.key, entry.value as String);
        }
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value('location');
        await response.listen((_) {}).cancel();
        if (location == null || redirects >= 5) {
          throw const VideoCacheException('缓存来源重定向失败');
        }
        url = url.resolve(location);
        continue;
      }
      if ([401, 403].contains(response.statusCode)) {
        await response.listen((_) {}).cancel();
        throw const VideoCacheException(
          '缓存来源认证失败或没有下载权限',
          refreshTransfer: true,
        );
      }
      if ([408, 429, 500, 502, 503, 504].contains(response.statusCode)) {
        await response.listen((_) {}).cancel();
        throw const VideoCacheException('缓存网络连接失败', transient: true);
      }
      return response;
    }
  }

  Future<void> transfer(
    Map<String, dynamic> file,
    _TransferControl control,
  ) async {
    final descriptor = await resolve(file);
    if (descriptor['identity'] != file['identity']) {
      throw const VideoCacheException('缓存来源身份已变更');
    }
    control.http?.close(force: true);
    control.http = null;
    await control.native?.close();
    control.native = null;
    final current = await metadata(descriptor, file['path'] as String, control);
    if (current['size'] != file['size'] ||
        current['version'] != file['version']) {
      throw const VideoCacheException('缓存源文件已变更，请先删除旧缓存');
    }
    if (control.stopped) return;
    await validateDestination(file);
    await space([file]);
    final target = File(file['destination'] as String);
    final partial = File('${target.path}.partial');
    var offset = file['committed'] as int? ?? 0;
    if ((!await partial.exists() && offset > 0) ||
        await partial.exists() && await partial.length() < offset) {
      throw const VideoCacheException('缓存断点文件已变更，请删除后重新缓存');
    }
    final outputFile = await partial.open(mode: FileMode.append);
    var persisted = DateTime.now(),
        published = DateTime.now(),
        sampled = DateTime.now();
    var sampleBytes = offset;
    file['received'] = offset;
    Future<void> checkpoint() async {
      await outputFile.flush();
      file['committed'] = offset;
      await save(file);
      persisted = DateTime.now();
    }

    Future<void> write(List<int> bytes) async {
      if (control.stopped) return;
      if (offset + bytes.length > (file['size'] as int)) {
        throw const VideoCacheException('缓存响应范围无效');
      }
      await outputFile.writeFrom(bytes);
      offset += bytes.length;
      file['received'] = offset;
      final now = DateTime.now();
      if (now.difference(sampled).inMilliseconds >= 1000) {
        file['speed'] =
            (offset - sampleBytes) *
            1000 /
            now.difference(sampled).inMilliseconds;
        sampled = now;
        sampleBytes = offset;
      }
      if (now.difference(published).inMilliseconds >= 250) {
        publish(file);
        published = now;
      }
      if (now.difference(persisted).inSeconds >= 2) {
        await checkpoint();
        final information = disk(file['root'] as String);
        if ((information['available'] as int) < margin) {
          throw const VideoCacheException('缓存磁盘可用空间不足');
        }
      }
    }

    try {
      await outputFile.truncate(offset);
      await outputFile.setPosition(offset);
      if (offset < (file['size'] as int)) {
        if (descriptor['kind'] == 'native') {
          await control.native!.openStream(
            descriptor['nativePath'] as String? ?? file['path'] as String,
            offset,
          );
          while (!control.stopped && offset < (file['size'] as int)) {
            final bytes = await control.native!.readStream(
              min(1024 * 1024, (file['size'] as int) - offset),
            );
            if (bytes.isEmpty) {
              throw const VideoCacheException('缓存下载提前结束', transient: true);
            }
            await write(bytes);
          }
        } else {
          final response = await http(
            descriptor,
            control,
            'bytes=$offset-${(file['size'] as int) - 1}',
            version: file['version'] as String,
          );
          if (response.statusCode != 206 ||
              response.headers.value('content-range') !=
                  'bytes $offset-${(file['size'] as int) - 1}/${file['size']}' ||
              ![
                null,
                'identity',
              ].contains(response.headers.value('content-encoding')) ||
              response.headers.value(file['validator'] as String) !=
                  file['version']) {
            await response.listen((_) {}).cancel();
            throw const VideoCacheException('缓存响应范围或版本无效');
          }
          await for (final bytes in response.timeout(
            const Duration(seconds: 30),
          )) {
            if (control.stopped) break;
            await write(bytes);
          }
        }
      }
      await checkpoint();
    } finally {
      // 失败时只提交已经刷盘的字节，下次不会信任未确认尾部。
      try {
        await checkpoint();
      } finally {
        await outputFile.close();
      }
    }
    if (control.stopped) return;
    if (offset != file['size']) {
      throw const VideoCacheException('缓存下载提前结束', transient: true);
    }
    await control.native?.closeStream();
    final finalMetadata = await metadata(
      descriptor,
      file['path'] as String,
      control,
    );
    if (finalMetadata['size'] != file['size'] ||
        finalMetadata['version'] != file['version']) {
      throw const VideoCacheException('缓存源文件已变更，请先删除旧缓存');
    }
    file['state'] = 'finalizing';
    await save(file);
    if (await target.exists()) {
      throw const VideoCacheException('缓存目标文件已存在，请先删除旧缓存');
    }
    await partial.rename(target.path);
    file['state'] = 'completed';
    file['speed'] = 0.0;
    await save(file);
    publish(file);
  }
}
