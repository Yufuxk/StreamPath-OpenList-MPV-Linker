import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// 用小块离屏绘制预热影视背景 shader，完成后释放临时图片。
Future<void> warmFilmShaders() async {
  final decoded = Completer<ui.Image>();
  final pixels = Uint8List(64 * 36 * 4);
  for (var index = 0; index < pixels.length; index += 4) {
    pixels[index] = 160;
    pixels[index + 1] = 100;
    pixels[index + 2] = 200;
    pixels[index + 3] = 255;
  }
  ui.decodeImageFromPixels(
    pixels,
    64,
    36,
    ui.PixelFormat.rgba8888,
    decoded.complete,
  );
  final image = await decoded.future;
  try {
    await _FilmShaderWarmUp(image).execute();
  } finally {
    image.dispose();
  }
}

class _FilmShaderWarmUp extends ShaderWarmUp {
  _FilmShaderWarmUp(this.image);

  final ui.Image image;

  @override
  ui.Size get size => const ui.Size(256, 144);

  @override
  Future<void> warmUpOnCanvas(ui.Canvas canvas) async {
    const bounds = ui.Rect.fromLTWH(0, 0, 256, 144);
    const source = ui.Rect.fromLTWH(0, 0, 64, 36);
    canvas.saveLayer(bounds, ui.Paint());
    canvas.drawImageRect(
      image,
      source,
      bounds,
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    canvas.drawRect(
      bounds,
      ui.Paint()
        ..blendMode = ui.BlendMode.dstIn
        ..shader = ui.Gradient.radial(
          bounds.center,
          102,
          const [
            ui.Color(0xffffffff),
            ui.Color(0xffffffff),
            ui.Color(0x00ffffff),
          ],
          const [0, .39, .65],
        ),
    );
    canvas.restore();
  }
}
