import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:streampath/domain/services/film_logo_selector.dart';

Uint8List _png(img.Image image) => Uint8List.fromList(img.encodePng(image));

img.Image _solid(int r, int g, int b, {int width = 96, int height = 32}) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(r, g, b, 255));
  return image;
}

img.Image _stripes(
  List<(int, int, int)> colors, {
  int width = 96,
  int height = 32,
}) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (var x = 0; x < width; x++) {
    final (r, g, b) =
        colors[(x * colors.length ~/ width).clamp(0, colors.length - 1)];
    for (var y = 0; y < height; y++) {
      image.setPixel(x, y, img.ColorRgba8(r, g, b, 255));
    }
  }
  return image;
}

void main() {
  test('light colorful logo outranks white and black variants', () {
    final black = analyzeLogoColor(_png(_solid(0, 0, 0)));
    final white = analyzeLogoColor(_png(_solid(255, 255, 255)));
    final colorful = analyzeLogoColor(
      _png(_stripes([(255, 205, 130), (190, 235, 200), (185, 205, 255)])),
    );
    expect(colorful.rank, greaterThan(white.rank));
    expect(white.rank, greaterThan(black.rank));
    expect(colorful.lightShare, greaterThan(.5));
    expect(black.heavyShare, greaterThan(.5));
  });

  test(
    'high-resolution colorful logo wins over low-resolution white logo',
    () async {
      final files = {
        '/color.png': _png(
          _stripes([(255, 205, 130), (190, 235, 200), (185, 205, 255)]),
        ),
        '/white.png': _png(_solid(255, 255, 255)),
      };
      final chosen = await selectBestLogo(const [
        LogoChoice('/color.png', 1524, 1),
        LogoChoice('/white.png', 347, 1),
      ], read: (path) async => files[path]!);
      expect(chosen, '/color.png');
    },
  );

  test('同分候选按原产地 > 中文 > 英文 > 其他选择', () async {
    final png = _png(
      _stripes([(255, 205, 130), (190, 235, 200), (185, 205, 255)]),
    );
    final chosen = await selectBestLogo(const [
      LogoChoice('/other.png', 800, 3),
      LogoChoice('/en.png', 800, 2),
      LogoChoice('/zh.png', 800, 1),
      LogoChoice('/original.png', 800, 0),
    ], read: (_) async => png);
    expect(chosen, '/original.png');
  });

  test('明显更好的彩色高分辨率候选可以压过原产地低分辨率候选', () async {
    final colorful = _png(
      _stripes([(255, 205, 130), (190, 235, 200), (185, 205, 255)]),
    );
    final white = _png(_solid(255, 255, 255));
    final chosen = await selectBestLogo(const [
      LogoChoice('/original-white.png', 347, 0),
      LogoChoice('/zh-color.png', 1524, 1),
    ], read: (path) async => path == '/zh-color.png' ? colorful : white);
    expect(chosen, '/zh-color.png');
  });

  test('failed candidate is skipped without aborting the comparison', () async {
    final chosen = await selectBestLogo(
      const [
        LogoChoice('/missing.png', 1200, 1),
        LogoChoice('/color.png', 1524, 1),
      ],
      read: (path) async {
        if (path == '/missing.png') throw const FormatException('broken');
        return _png(
          _stripes([(255, 205, 130), (190, 235, 200), (185, 205, 255)]),
        );
      },
    );
    expect(chosen, '/color.png');
  });

  test('single candidate is returned without downloading', () async {
    var reads = 0;
    final chosen = await selectBestLogo(
      const [LogoChoice('/only.png', 800, 0)],
      read: (_) async {
        reads++;
        return Uint8List(0);
      },
    );
    expect(chosen, '/only.png');
    expect(reads, 0);
  });
}
