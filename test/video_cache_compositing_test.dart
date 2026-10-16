import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';
import 'package:streampath/presentation/widgets/glass_surface.dart';

class _Stripes extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0; x < size.width; x += 8) {
      canvas.drawRect(
        Rect.fromLTWH(x.toDouble(), 0, 8, size.height),
        Paint()..color = x % 16 == 0 ? Colors.white : Colors.black,
      );
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => false;
}

void main() {
  testWidgets('隔离透明度、缩放和重绘边界对真实背景采样的影响', (tester) async {
    final boundary = GlobalKey();
    final variation = <String, int>{};
    for (final mode in ['static', 'opacity', 'scale', 'boundary', 'clip']) {
      Widget panel = const GlassSurface(
        level: GlassSurfaceLevel.raised,
        borderRadius: BorderRadius.all(Radius.circular(16)),
        blur: true,
        blurSigma: 20,
        child: SizedBox.expand(),
      );
      panel = SizedBox(width: 300, height: 240, child: panel);
      panel = switch (mode) {
        'opacity' => Opacity(opacity: .7, child: panel),
        'scale' => Transform.scale(scale: .8, child: panel),
        'boundary' => RepaintBoundary(child: panel),
        'clip' => ClipRect(clipper: _HalfClip(), child: panel),
        _ => panel,
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.videoCachePanelTheme(AppTheme.dark(glass: true)),
          home: RepaintBoundary(
            key: boundary,
            child: Stack(
              children: [
                Positioned.fill(child: CustomPaint(painter: _Stripes())),
                Positioned(right: 40, bottom: 40, child: panel),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final rgba = (await image.toByteData())!.buffer.asUint8List();
        // 所有方案共同可见的内部区域，避开描边和阴影。
        final samples = [
          for (var x = 650; x < 700; x++) rgba[(500 * image.width + x) * 4],
        ];
        variation[mode] =
            samples.reduce((a, b) => a > b ? a : b) -
            samples.reduce((a, b) => a < b ? a : b);
        final directory = Directory('build/cache-panel-animation');
        await directory.create(recursive: true);
        await File('${directory.path}/isolation-$mode.png').writeAsBytes(
          (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List(),
        );
        image.dispose();
      });
    }
    await tester.runAsync(
      () => File(
        'build/cache-panel-animation/isolation.txt',
      ).writeAsString('$variation'),
    );
    expect(variation['opacity']!, greaterThan(40));
    for (final mode in ['static', 'scale', 'boundary', 'clip']) {
      expect(variation[mode]!, lessThan(6), reason: mode);
    }
  });
}

class _HalfClip extends CustomClipper<Rect> {
  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(size.width / 2, size.height / 2, size.width, size.height);
  @override
  bool shouldReclip(_HalfClip oldClipper) => false;
}
