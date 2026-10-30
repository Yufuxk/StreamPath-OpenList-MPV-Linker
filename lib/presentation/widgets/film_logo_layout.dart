import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// 透明留白不参与布局；有字形目标时估算字形大小，无目标时按可用空间等比适配。
class FilmLogoLayout {
  const FilmLogoLayout(
    this.bounds,
    this.glyphExtent,
    this.nearBlack,
    this.hasBrightEdge,
  );

  final Rect bounds;
  final double glyphExtent;

  /// 墨色是否明确接近纯黑。
  final bool nearBlack;

  /// 透明边缘处是否已有高亮描边或光晕；这类徽标不需要再补对比描边。
  final bool hasBrightEdge;

  /// 近乎纯黑判定：alpha 加权平均最大通道低于该亮度，避免彩色或灰白徽标被误判。
  static const nearBlackThreshold = 48.0;

  /// 自带描边判定：轮廓像素中超过半数达到该最大通道亮度。
  static const brightEdgeThreshold = 160.0;

  static FilmLogoLayout? analyze(Uint8List rgba, int width, int height) {
    var left = width, top = height, right = -1, bottom = -1;
    final rows = Float64List(height), columns = Float64List(width);
    var toneWeight = 0.0, tone = 0.0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final offset = (y * width + x) * 4;
        final alpha = rgba[offset + 3];
        if (alpha <= 8) continue;
        toneWeight += alpha;
        tone +=
            alpha *
            math.max(
              math.max(rgba[offset], rgba[offset + 1]),
              rgba[offset + 2],
            );
        left = math.min(left, x);
        right = math.max(right, x);
        top = math.min(top, y);
        bottom = math.max(bottom, y);
        if (alpha >= 64) {
          rows[y] += alpha;
          columns[x] += alpha;
        }
      }
    }
    if (right < left) return null;
    final bounds = Rect.fromLTRB(
      left.toDouble(),
      top.toDouble(),
      (right + 1).toDouble(),
      (bottom + 1).toDouble(),
    );
    var edgeCount = 0, edgeBright = 0;
    for (var y = top; y <= bottom; y++) {
      for (var x = left; x <= right; x++) {
        final offset = (y * width + x) * 4;
        if (rgba[offset + 3] <= 8) continue;
        final outline =
            (x == 0 || rgba[offset - 1] <= 8) ||
            (x == width - 1 || rgba[offset + 7] <= 8) ||
            (y == 0 || rgba[offset - width * 4 + 3] <= 8) ||
            (y == height - 1 || rgba[offset + width * 4 + 3] <= 8);
        if (!outline) continue;
        edgeCount++;
        if (math.max(
              math.max(rgba[offset], rgba[offset + 1]),
              rgba[offset + 2],
            ) >=
            brightEdgeThreshold) {
          edgeBright++;
        }
      }
    }
    final vertical = bounds.height > bounds.width * 1.25;
    final projection = vertical ? columns : rows;
    final start = vertical ? left : top, end = vertical ? right : bottom;
    final peak = projection.reduce(math.max);
    final maxGap = math.max(1, ((end - start + 1) * .06).round());
    var bandStart = start, lastInk = start, ink = 0.0, bestInk = 0.0;
    var extent = (end - start + 1).toDouble();
    for (var i = start; i <= end + maxGap + 1; i++) {
      if (i <= end && projection[i] > peak * .12) {
        if (ink == 0) bandStart = i;
        lastInk = i;
        ink += projection[i];
      } else if (ink > 0 && i - lastInk > maxGap) {
        if (ink > bestInk) {
          bestInk = ink;
          extent = (lastInk - bandStart + 1).toDouble();
        }
        ink = 0;
      }
    }
    return FilmLogoLayout(
      bounds,
      extent,
      toneWeight != 0 && tone / toneWeight < nearBlackThreshold,
      edgeCount != 0 && edgeBright / edgeCount >= .5,
    );
  }

  Rect destination(Size size, double? glyphSize) {
    final fitScale = math.min(
      size.width / bounds.width,
      size.height / bounds.height,
    );
    var preferredScale = glyphSize == null ? fitScale : glyphSize / glyphExtent;
    if (glyphSize != null && bounds.width > bounds.height * 1.25) {
      // 装饰与多行文字可能放大字形估算，横排徽标保留可读宽度。
      final minimumWidth = math.min(glyphSize * 4.5, size.width * .75);
      preferredScale = math.max(preferredScale, minimumWidth / bounds.width);
    }
    final scale = math.min(preferredScale, fitScale);
    final width = bounds.width * scale, height = bounds.height * scale;
    return Rect.fromLTWH(
      (size.width - width) / 2,
      size.height - height,
      width,
      height,
    );
  }
}
