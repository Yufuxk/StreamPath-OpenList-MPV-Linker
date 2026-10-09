import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';

void main() {
  for (final cached in [false, true]) {
    testWidgets('封面解码后淡入，普通重建不重播，切图重新淡入 cached=$cached', (tester) async {
      final fixture = await tester.runAsync(() async {
        final temp = await Directory.systemTemp.createTemp('film_cover_fade_');
        final tmdb = TmdbMetadataService(credentials: _NoToken());
        final cache = FilmCatalogImageCache(temp, tmdb);
        final bytes = await File('assets/tmdb_logo.png').readAsBytes();
        for (final path in ['/first.png', '/second.png']) {
          await File(
            p.join(
              temp.path,
              '${FilmCatalogImageCache.cacheKey(path, 'w342')}.img',
            ),
          ).writeAsBytes(bytes);
          await cache.cached(path, 'w342');
        }
        return (temp, tmdb, cache);
      });
      final (temp, tmdb, cache) = fixture!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        cache.close();
        tmdb.close();
        PaintingBinding.instance.imageCache.clear();
        await tester.runAsync(() => temp.delete(recursive: true));
      });
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      if (cached) {
        await tester.runAsync(
          () => precacheImage(
            filmArtworkProvider(cache.knownFile('/first.png', 'w342')!),
            tester.element(find.byType(Scaffold)),
          ),
        );
      }
      Widget frame(String path) => MaterialApp(
        home: Center(
          child: FilmArtwork(cache: cache, path: path, width: 100, height: 150),
        ),
      );
      double opacity() => tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(FilmArtwork),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;
      Future<void> decode() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          final images = tester.widgetList<RawImage>(find.byType(RawImage));
          if (images.any((image) => image.image != null)) return;
        }
        fail('Cover did not decode');
      }

      await tester.pumpWidget(frame('/first.png'));
      await decode();
      expect(opacity(), 0);
      await tester.pump(const Duration(milliseconds: 70));
      expect(opacity(), allOf(greaterThan(0), lessThan(1)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(opacity(), 1);
      await tester.pumpWidget(frame('/first.png'));
      expect(opacity(), 1);
      await tester.pumpWidget(frame('/second.png'));
      await decode();
      expect(opacity(), 0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(opacity(), 1);
      expect(tester.takeException(), isNull);
    });
  }
}

class _NoToken extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}
