import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../data/models/film_catalog_item.dart';

/// 派生图只读取本地文件；一个生成任务与一个最新候选共享磁盘预算。
class FilmBackdropBlurCache {
  FilmBackdropBlurCache(
    this.directory, {
    this.budgetBytes = 32 * 1024 * 1024,
    this.maintainBudget,
  });
  final Directory directory;
  final int budgetBytes;
  final Future<void> Function(File, File?)? maintainBudget;
  bool _initialized = false;
  _BlurRequest? _current, _next;
  Future<void>? _running;
  bool _closed = false, _clearing = false;
  int _generation = 0;

  // 为 Windows 解码器及临时后缀预留路径空间。
  static String _identity(File file) => sha256
      .convert(utf8.encode(p.normalize(p.absolute(file.path))))
      .toString()
      .substring(0, 32);

  Future<File?> get(File source, {File? thumbnail}) {
    if (_closed || _clearing) return Future.value(null);
    final identity = (source.path, thumbnail?.path);
    if (_current?.identity == identity) return _current!.result.future;
    if (_next?.identity == identity) return _next!.result.future;
    _next?.result.complete(null);
    final request = _BlurRequest(source, thumbnail);
    _next = request;
    _running ??= _run();
    return request.result.future;
  }

  Future<void> _run() async {
    // 让 _running 在同步完成前取得 Future。
    await Future<void>.value();
    try {
      while (_next != null && !_closed && !_clearing) {
        final request = _current = _next!;
        _next = null;
        try {
          request.result.complete(await _prepare(request, _generation));
        } on FileSystemException catch (error) {
          debugPrint(
            'Film backdrop cache I/O failed: ${error.osError?.errorCode}',
          );
          request.result.complete(null);
        } on FilmCatalogException catch (error) {
          debugPrint('Film backdrop cache failed: ${error.code}');
          request.result.complete(null);
        } catch (error, stack) {
          request.result.completeError(error, stack);
        } finally {
          _current = null;
        }
      }
    } finally {
      _running = null;
    }
  }

  Future<File?> _prepare(_BlurRequest request, int generation) async {
    final source = request.source;
    final stat = await source.stat();
    if (stat.type != FileSystemEntityType.file) {
      await removeSource(source);
      return null;
    }
    if (_closed || _clearing || generation != _generation) return null;
    await maintainBudget?.call(source, request.thumbnail);
    var input = request.thumbnail ?? source;
    var inputStat = await input.stat();
    if (inputStat.type != FileSystemEntityType.file) {
      input = source;
      inputStat = stat;
    }
    final prefix = _identity(source);
    final version = sha256
        .convert(
          utf8.encode(
            '${stat.size}:${stat.modified.microsecondsSinceEpoch}\n'
            '${input.path}:${inputStat.size}:${inputStat.modified.microsecondsSinceEpoch}\n'
            'adaptive-blur-v2:768x432:radius18:saturation.84:jpeg80',
          ),
        )
        .toString()
        .substring(0, 32);
    final file = File(p.join(directory.path, '$prefix-$version.jpg'));
    await directory.create(recursive: true);
    if (!_initialized) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.partial')) {
          await entity.delete();
        }
      }
      _initialized = true;
    }
    if (await file.exists()) {
      try {
        await _decode(file);
        await file.setLastModified(DateTime.now());
        await _prune();
        return await file.exists() ? file : null;
      } on FilmCatalogException {
        await file.delete();
      }
    }
    final (pixels, width, height) = await _pixels(input);
    final encoded = await Isolate.run(() => _blur(pixels, width, height));
    final latest = await source.stat();
    if (_closed ||
        _clearing ||
        generation != _generation ||
        latest.type != FileSystemEntityType.file ||
        latest.size != stat.size ||
        latest.modified != stat.modified) {
      return null;
    }
    final partial = File('${file.path}.partial');
    try {
      await partial.writeAsBytes(encoded, flush: true);
      await _decode(partial);
      if (_closed || _clearing || generation != _generation) return null;
      await partial.rename(file.path);
      // 同一源文件只保留当前预处理版本。
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File &&
            entity.path != file.path &&
            p.basename(entity.path).startsWith('$prefix-')) {
          await entity.delete();
        }
      }
      await _prune();
      return await file.exists() ? file : null;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  static Future<(Uint8List, int, int)> _pixels(File file) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final scale = math.min(
        1.0,
        math.min(768 / descriptor.width, 432 / descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      image = (await codec.getNextFrame()).image;
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!;
      return (
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        image.width,
        image.height,
      );
    } on Exception {
      throw const FilmCatalogException('invalidImage');
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static Uint8List _blur(Uint8List pixels, int width, int height) {
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: pixels.buffer,
      bytesOffset: pixels.offsetInBytes,
      numChannels: 4,
    );
    // 透明像素先合成为不透明低频底色，JPEG 不保留 Alpha。
    for (final pixel in image) {
      final alpha = pixel.a / 255;
      pixel
        ..r = pixel.r * alpha + 24 * (1 - alpha)
        ..g = pixel.g * alpha + 24 * (1 - alpha)
        ..b = pixel.b * alpha + 24 * (1 - alpha)
        ..a = 255;
    }
    img.gaussianBlur(image, radius: math.min(18, math.min(width, height) - 1));
    // 在 RGB 内按 HSV 的最大通道降饱和，保留中性灰的亮度。
    for (final pixel in image) {
      final value = math.max(pixel.r, math.max(pixel.g, pixel.b));
      pixel
        ..r = value + (pixel.r - value) * .84
        ..g = value + (pixel.g - value) * .84
        ..b = value + (pixel.b - value) * .84;
    }
    return img.encodeJpg(image, quality: 80);
  }

  static Future<void> _decode(File file) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      codec = await descriptor.instantiateCodec();
      (await codec.getNextFrame()).image.dispose();
    } on Exception {
      throw const FilmCatalogException('invalidImage');
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<void> _prune() async {
    final files = <(File, FileStat)>[];
    var total = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.jpg')) continue;
      final stat = await entity.stat();
      files.add((entity, stat));
      total += stat.size;
    }
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (file, stat) in files) {
      if (total <= budgetBytes) break;
      await file.delete();
      total -= stat.size;
    }
  }

  Future<void> removeSource(File source) async {
    if (!await directory.exists()) return;
    final prefix = '${_identity(source)}-';
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && p.basename(entity.path).startsWith(prefix)) {
        await entity.delete();
      }
    }
  }

  Future<void> clear() async {
    _clearing = true;
    _generation++;
    _next?.result.complete(null);
    _next = null;
    try {
      await _running;
      if (await directory.exists()) {
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is File) await entity.delete();
        }
      }
    } finally {
      _clearing = false;
    }
  }

  void close() {
    _closed = true;
    _generation++;
    _next?.result.complete(null);
    _next = null;
  }
}

class _BlurRequest {
  _BlurRequest(this.source, this.thumbnail);
  final File source;
  final File? thumbnail;
  final result = Completer<File?>();
  (String, String?) get identity => (source.path, thumbnail?.path);
}
