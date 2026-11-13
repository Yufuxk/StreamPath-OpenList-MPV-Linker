import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_image_reference.dart';
import 'film_catalog_image_cache.dart';

/// 人工图片是持久资料，不参与可重建图片缓存的淘汰。
class FilmMetadataArtwork {
  FilmMetadataArtwork(this.directory, this.cache);
  final Directory directory;
  final FilmCatalogImageCache cache;
  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );
  final _tokens = <CancelToken>{};
  final _readCancels = <Completer<File>>{};
  final _created = <String>{};
  bool _closed = false;
  void track(Iterable<String> references) {
    for (final value in references) {
      final ref = FilmImageReference.parse(value);
      if (ref?.origin == 'asset' &&
          RegExp(r'^imported_artwork/[a-f0-9]{64}\.bin$').hasMatch(ref!.path)) {
        _created.add(p.join(directory.path, p.basename(ref.path)));
      }
    }
  }

  void cancelDownloads() {
    for (final token in _tokens) {
      token.cancel();
    }
    for (final pending in _readCancels) {
      if (!pending.isCompleted) {
        pending.completeError(const FilmCatalogException('cancelled'));
      }
    }
  }

  Future<String> fromFile(File file) async {
    if (await file.length() > cache.maxImageBytes) {
      throw const FilmCatalogException('imageTooLarge');
    }
    return _store(await file.readAsBytes());
  }

  Future<String> fromReference(String path) async {
    final cancel = Completer<File>();
    _readCancels.add(cancel);
    try {
      return await fromFile(
        await Future.any([cache.get(path, target: 'original'), cancel.future]),
      );
    } finally {
      _readCancels.remove(cancel);
    }
  }

  Future<String> fromUrl(String value) async {
    final token = CancelToken();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FilmCatalogException('invalidImage');
    }
    _tokens.add(token);
    try {
      return await (() async {
        final response = await _dio.get<ResponseBody>(
          uri.toString(),
          options: Options(responseType: ResponseType.stream),
          cancelToken: token,
        );
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.data!.stream) {
          if (bytes.length + chunk.length > cache.maxImageBytes) {
            token.cancel();
            throw const FilmCatalogException('imageTooLarge');
          }
          bytes.add(chunk);
        }
        if (token.isCancelled) throw const FilmCatalogException('cancelled');
        return _store(bytes.takeBytes());
      })().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          token.cancel();
          throw const FilmCatalogException('imageDownloadTimeout');
        },
      );
    } on DioException catch (error) {
      throw FilmCatalogException(
        CancelToken.isCancel(error) ? 'cancelled' : 'imageDownloadFailed',
      );
    } finally {
      _tokens.remove(token);
    }
  }

  Future<String> _store(Uint8List bytes) async {
    if (bytes.length > cache.maxImageBytes) {
      throw const FilmCatalogException('imageTooLarge');
    }
    final png =
        bytes.length >= 8 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71;
    final jpg =
        bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255;
    final webp =
        bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP';
    if (!png && !jpg && !webp) throw const FilmCatalogException('invalidImage');
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 16);
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    } on Exception {
      throw const FilmCatalogException('invalidImage');
    }
    if (_closed) throw const FilmCatalogException('cancelled');
    final name = '${sha256.convert(bytes)}.bin';
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, name));
    if (!await file.exists()) {
      await file.writeAsBytes(bytes, flush: true);
      _created.add(file.path);
    }
    return FilmImageReference(
      'asset',
      'app',
      'imported_artwork/$name',
    ).encode();
  }

  void cancel() {
    _closed = true;
    cancelDownloads();
    _dio.close(force: true);
  }

  Future<void> cleanup(Set<String> references) async {
    for (final path in _created) {
      final ref = FilmImageReference(
        'asset',
        'app',
        'imported_artwork/${p.basename(path)}',
      ).encode();
      if (!references.contains(ref) && await File(path).exists()) {
        await File(path).delete();
      }
    }
    _created.clear();
  }
}
