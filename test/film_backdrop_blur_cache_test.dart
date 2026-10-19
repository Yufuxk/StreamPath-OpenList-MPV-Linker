import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/domain/services/film_backdrop_blur_cache.dart';

void main() {
  testWidgets('预模糊保留中性灰亮度，不产生黑色斑点', (tester) async {
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('blur_gray_');
      final cache = FilmBackdropBlurCache(
        Directory(p.join(temp.path, 'derived')),
      );
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xff999999), BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, 64);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final source = await File(
        p.join(temp.path, 'gray.png'),
      ).writeAsBytes(bytes!.buffer.asUint8List());
      try {
        final output = (await cache.get(source))!;
        final codec = await ui.instantiateImageCodec(
          await output.readAsBytes(),
        );
        final decoded = (await codec.getNextFrame()).image;
        final pixels = (await decoded.toByteData())!.buffer.asUint8List();
        decoded.dispose();
        codec.dispose();
        for (var i = 0; i < pixels.length; i += 4) {
          expect(pixels[i], closeTo(153, 3));
          expect(pixels[i + 1], closeTo(153, 3));
          expect(pixels[i + 2], closeTo(153, 3));
        }
      } finally {
        cache.close();
        await cache.clear();
        await temp.delete(recursive: true);
      }
    });
  });

  testWidgets('派生图复用、损坏重建、源版本与清理隔离', (tester) async {
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('blur_cache_');
      // 原生解码器读取临时文件的路径仍须控制长度。
      final derived = Directory(p.join(temp.path, 'derived_${'a' * 75}'));
      final cache = FilmBackdropBlurCache(derived);
      final source = File(p.join(temp.path, 'source.png'));
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xff336699), BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(1600, 900);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      await source.writeAsBytes(bytes);
      try {
        final first = (await cache.get(source))!;
        final originalBytes = await source.readAsBytes();
        final encoded = await first.readAsBytes();
        final buffer = await ui.ImmutableBuffer.fromFilePath(first.path);
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        expect(descriptor.width, 768);
        expect(descriptor.height, 432);
        descriptor.dispose();
        buffer.dispose();
        final hit = (await cache.get(source))!;
        expect(hit.path, first.path);
        expect(await hit.readAsBytes(), encoded);
        await hit.writeAsString('corrupt');
        final rebuilt = (await cache.get(source))!;
        expect(rebuilt.path, first.path);
        expect(await rebuilt.readAsBytes(), encoded);
        await source.setLastModified(
          DateTime.now().add(const Duration(seconds: 2)),
        );
        final changed = (await cache.get(source))!;
        expect(changed.path, isNot(first.path));
        expect(await first.exists(), isFalse);
        expect(await source.readAsBytes(), originalBytes);
        await cache.clear();
        expect(await derived.list().length, 0);
        expect(await source.exists(), isTrue);
        cache.close();
        expect(await cache.get(source), isNull);
      } finally {
        cache.close();
        await cache.clear();
        await temp.delete(recursive: true);
      }
    });
  });

  testWidgets('生成队列只保留最新候选，失效源与LRU预算受控', (tester) async {
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('blur_queue_');
      final cache = FilmBackdropBlurCache(
        Directory(p.join(temp.path, 'derived')),
        budgetBytes: 12000,
      );
      final source = File(p.join(temp.path, 'a.png'));
      await source.writeAsBytes(
        await File('assets/tmdb_logo.png').readAsBytes(),
      );
      final b = await source.copy(p.join(temp.path, 'b.png'));
      final c = await source.copy(p.join(temp.path, 'c.png'));
      try {
        final aFuture = cache.get(source);
        await Future<void>.value();
        final bFuture = cache.get(b), cFuture = cache.get(c);
        expect(await bFuture, isNull);
        await aFuture;
        await cFuture;
        var total = 0;
        await for (final entity in cache.directory.list()) {
          if (entity is File) total += await entity.length();
        }
        expect(total, lessThanOrEqualTo(cache.budgetBytes));
        await c.delete();
        expect(await cache.get(c), isNull);
        final pending = cache.get(b);
        await cache.clear();
        await pending;
        expect(await cache.directory.list().length, 0);
        expect(await source.exists(), isTrue);
      } finally {
        cache.close();
        await cache.clear();
        await temp.delete(recursive: true);
      }
    });
  });
}
