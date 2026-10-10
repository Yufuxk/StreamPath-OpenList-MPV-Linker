import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_image_reference.dart';
import 'tmdb_metadata_service.dart';
import 'tmdb_http_client.dart';

/// 受限的 TMDB 图片缓存；下载客户端没有 API 或网盘凭据。
class FilmCatalogImageCache {
  FilmCatalogImageCache(
    this.directory,
    this.tmdb, {
    Dio? dio,
    this.maxImageBytes = 10 * 1024 * 1024,
    this.budgetBytes = 512 * 1024 * 1024,
    Future<void> Function(File)? validateImage,
    this.readReference,
  }) : _dio = dio ?? createTmdbDio(),
       _validateImage = validateImage ?? _decode;
  final Directory directory;
  final TmdbMetadataService tmdb;
  final Dio _dio;
  final int maxImageBytes, budgetBytes;
  final Future<Uint8List> Function(FilmImageReference, int)? readReference;
  final Future<void> Function(File) _validateImage;
  final Map<String, Future<File>> _pending = {};
  final Map<String, Future<File>> _downloads = {};
  final Map<(String, String), File> _knownFiles = {};
  Future<void>? _configurationLoad;
  Future<void> _pruneTail = Future.value();
  Map<String, int>? _fileSizes;
  int _cachedBytes = 0;
  final List<Completer<void>> _waiters = [];
  final Set<CancelToken> _tokens = {};
  final Set<String> _protected = {};
  int _active = 0;
  bool _closed = false;
  Future<void>? _initialized;
  Map<String, dynamic>? _images;
  String _imageHost = 'image.tmdb.org';
  static const _cdnHost = 'tmdb-image-prod.b-cdn.net';

  static String cacheKey(String path, String size) =>
      sha256.convert(utf8.encode('$size\n$path')).toString();

  static void _checkPath(String path) {
    if (FilmImageReference.parse(path) != null) return;
    if (!RegExp(
      r'^/[A-Za-z0-9_-]+\.(jpg|png|webp)$',
      caseSensitive: false,
    ).hasMatch(path)) {
      throw const FilmCatalogException('invalidImage');
    }
  }

  Future<void> _initialize() async {
    await directory.create(recursive: true);
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.partial')) {
        await entity.delete();
      }
    }
    final config = File(p.join(directory.path, 'configuration.json'));
    if (await config.exists()) {
      try {
        final data = jsonDecode(await config.readAsString());
        if (data is Map<String, dynamic>) _images = data;
      } on FormatException {
        /* 可重建的配置缓存 */
      }
    }
  }

  /// 已确认的文件位置供首帧使用；只保存路径，不持有解码图片。
  File? knownFile(String? path, String target) => _knownFiles[(path, target)];

  File _rememberFile(String path, String target, File file) {
    if (_closed) return file;
    final key = (path, target);
    _knownFiles.remove(key);
    _knownFiles[key] = file;
    if (_knownFiles.length > 128) _knownFiles.remove(_knownFiles.keys.first);
    return file;
  }

  Future<File?> cached(String path, String target) async {
    _checkPath(path);
    await (_initialized ??= _initialize());
    final direct = File(
      p.join(directory.path, '${cacheKey(path, target)}.img'),
    );
    if (await direct.exists()) return _rememberFile(path, target, direct);
    if (!await directory.exists()) _fileSizes = null;
    if (_images != null) {
      final size = _size(_images!, target);
      final alternative = File(
        p.join(directory.path, '${cacheKey(path, size)}.img'),
      );
      if (await alternative.exists()) {
        return _rememberFile(path, target, alternative);
      }
    }
    _knownFiles.remove((path, target));
    return null;
  }

  static String _size(Map<String, dynamic> images, String target) {
    final raw =
        images[switch (target) {
          'w780' || 'original' => 'backdrop_sizes',
          'w300' => 'still_sizes',
          _ => 'poster_sizes',
        }];
    if (raw is! List) throw const FilmCatalogException('invalidImage');
    if (target == 'original') {
      if (!raw.contains('original')) {
        throw const FilmCatalogException('invalidImage');
      }
      return target;
    }
    final sizes =
        raw
            .whereType<String>()
            .where((v) => RegExp(r'^w\d+$').hasMatch(v))
            .toList()
          ..sort(
            (a, b) =>
                int.parse(a.substring(1)).compareTo(int.parse(b.substring(1))),
          );
    if (sizes.contains(target)) return target;
    if (sizes.isEmpty) throw const FilmCatalogException('invalidImage');
    final width = int.parse(target.substring(1));
    return sizes.firstWhere(
      (v) => int.parse(v.substring(1)) >= width,
      orElse: () => sizes.last,
    );
  }

  Future<File> get(String path, {String target = 'w342'}) async {
    _checkPath(path);
    final key = '$target:$path';
    return _pending.putIfAbsent(
      key,
      () => _get(path, target)
          .then((file) => _rememberFile(path, target, file))
          .whenComplete(() {
            _pending.remove(key);
          }),
    );
  }

  Future<File> _get(String path, String target) async {
    if (_closed) throw const FilmCatalogException('cancelled');
    final existing = await cached(path, target);
    if (existing != null) return existing;
    if (_active >= 2) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    try {
      if (_closed) throw const FilmCatalogException('cancelled');
      final again = await cached(path, target);
      if (again != null) return again;
      if (FilmImageReference.parse(path) case final reference?) {
        if (readReference == null) {
          throw const FilmCatalogException('sourceUnavailable');
        }
        final file = File(
          p.join(directory.path, '${cacheKey(path, target)}.img'),
        );
        final partial = File('${file.path}.partial');
        _protected.add(file.path);
        try {
          final bytes = await readReference!(reference, maxImageBytes);
          if (_closed) throw const FilmCatalogException('cancelled');
          if (bytes.length > maxImageBytes) {
            throw const FilmCatalogException('imageTooLarge');
          }
          await directory.create(recursive: true);
          await partial.writeAsBytes(bytes, flush: true);
          await _validateImage(partial);
          await partial.rename(file.path);
          final prune = _pruneTail.then((_) => _prune(file));
          _pruneTail = prune.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          );
          await prune;
          return file;
        } finally {
          _protected.remove(file.path);
          if (await partial.exists()) await partial.delete();
        }
      }
      if (_images == null) await (_configurationLoad ??= _loadConfiguration());
      if (_images!['secure_base_url'] != 'https://image.tmdb.org/t/p/') {
        throw const FilmCatalogException('invalidImage');
      }
      final size = _size(_images!, target);
      final key = cacheKey(path, size);
      final file = File(p.join(directory.path, '$key.img'));
      return await _downloads.putIfAbsent(
        key,
        () => _fetchImage(file, 'https://image.tmdb.org/t/p/$size$path')
            .whenComplete(() {
              _downloads.remove(key);
            }),
      );
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }

  Future<void> _loadConfiguration() async {
    try {
      final config = await tmdb.configuration();
      final images = config['images'];
      if (images is! Map<String, dynamic> ||
          images['secure_base_url'] != 'https://image.tmdb.org/t/p/') {
        throw const FilmCatalogException('invalidImage');
      }
      await File(
        p.join(directory.path, 'configuration.json'),
      ).writeAsString(jsonEncode(images));
      _images = Map<String, dynamic>.from(images);
    } on Exception {
      _configurationLoad = null;
      rethrow;
    }
  }

  Future<File> _fetchImage(File file, String url) async {
    final partial = File('${file.path}.partial');
    _protected.add(file.path);
    final token = CancelToken();
    _tokens.add(token);
    final deadline = Timer(const Duration(seconds: 15), () => token.cancel());
    try {
      // 通用缓存清理可以移除目录，后续下载按当前配置重新建立缓存。
      await directory.create(recursive: true);
      final config = File(p.join(directory.path, 'configuration.json'));
      if (!await config.exists()) {
        await config.writeAsString(jsonEncode(_images));
      }
      final uri = Uri.parse(url);
      var host = _imageHost;
      try {
        await _download(uri.replace(host: host).toString(), partial, token);
      } on DioException catch (error) {
        if (token.isCancelled ||
            !switch (error.type) {
              DioExceptionType.connectionError ||
              DioExceptionType.connectionTimeout ||
              DioExceptionType.sendTimeout ||
              DioExceptionType.receiveTimeout => true,
              DioExceptionType.unknown => error.error is HandshakeException,
              _ => false,
            }) {
          rethrow;
        }
        host = host == 'image.tmdb.org' ? _cdnHost : 'image.tmdb.org';
        await _download(uri.replace(host: host).toString(), partial, token);
      }
      if (token.isCancelled) throw const FilmCatalogException('imageFailed');
      await _validateImage(partial);
      await partial.rename(file.path);
      _imageHost = host;
      final prune = _pruneTail.then((_) => _prune(file));
      _pruneTail = prune.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      await prune;
      return file;
    } on DioException {
      throw const FilmCatalogException('imageFailed');
    } on TimeoutException {
      throw const FilmCatalogException('imageFailed');
    } finally {
      deadline.cancel();
      token.cancel();
      _tokens.remove(token);
      _protected.remove(file.path);
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _download(String url, File partial, CancelToken token) async {
    final response = await _dio.get<ResponseBody>(
      url,
      cancelToken: token,
      options: Options(
        // 两次连接共用单图时限，预留图片传输时间。
        connectTimeout: const Duration(seconds: 5),
        responseType: ResponseType.stream,
        followRedirects: false,
        maxRedirects: 0,
        headers: {'Authorization': null},
        validateStatus: (s) => s == 200,
      ),
    );
    final declared = int.tryParse(
      response.headers.value('content-length') ?? '',
    );
    if (declared != null && declared > maxImageBytes) {
      throw const FilmCatalogException('imageTooLarge');
    }
    final sink = partial.openWrite();
    var bytes = 0;
    try {
      await for (final chunk in response.data!.stream) {
        bytes += chunk.length;
        if (bytes > maxImageBytes) {
          token.cancel();
          throw const FilmCatalogException('imageTooLarge');
        }
        sink.add(chunk);
      }
      await sink.flush();
    } on SocketException catch (error) {
      throw DioException.connectionError(
        requestOptions: response.requestOptions,
        reason: error.message,
        error: error,
      );
    } on HttpException catch (error) {
      throw DioException.connectionError(
        requestOptions: response.requestOptions,
        reason: error.message,
        error: error,
      );
    } finally {
      await sink.close();
    }
  }

  static Future<void> validatePortableImage(File file) => _decode(file);
  static Future<void> _decode(File file) async {
    final bytes = await file.readAsBytes();
    late ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(bytes, targetWidth: 500);
    } on Exception {
      throw const FilmCatalogException('invalidImage');
    }
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  }

  static bool _isCacheFile(File file) =>
      RegExp(r'^[a-f0-9]{64}\.img$').hasMatch(p.basename(file.path));

  Future<void> _prune(File added) async {
    if (_fileSizes != null) {
      final size = await added.length();
      _cachedBytes += size - (_fileSizes![added.path] ?? 0);
      _fileSizes![added.path] = size;
      if (_cachedBytes <= budgetBytes) return;
    }
    final files = <(File, FileStat)>[];
    var total = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !_isCacheFile(entity)) {
        continue;
      }
      final stat = await entity.stat();
      files.add((entity, stat));
      total += stat.size;
    }
    _fileSizes = {for (final entry in files) entry.$1.path: entry.$2.size};
    _cachedBytes = total;
    if (total <= budgetBytes) return;
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final entry in files) {
      if (total <= budgetBytes) break;
      if (_protected.contains(entry.$1.path)) continue;
      await entry.$1.delete();
      _knownFiles.removeWhere((_, file) => file.path == entry.$1.path);
      _fileSizes!.remove(entry.$1.path);
      total -= entry.$2.size;
      _cachedBytes = total;
    }
  }

  Future<void> clear() async {
    if (_active > 0) throw const FilmCatalogException('imageBusy');
    _knownFiles.clear();
    await (_initialized ??= _initialize());
    _fileSizes = null;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          RegExp(
            r'^[a-f0-9]{64}\.img(?:\.partial)?$',
          ).hasMatch(p.basename(entity.path))) {
        await entity.delete();
      }
    }
    _fileSizes = {};
    _cachedBytes = 0;
  }

  void close() {
    _closed = true;
    _knownFiles.clear();
    _fileSizes = null;
    for (final token in _tokens) {
      token.cancel();
    }
    _dio.close(force: true);
  }
}
