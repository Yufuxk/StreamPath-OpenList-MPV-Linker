import 'dart:math' as math;
import 'package:flutter/painting.dart';

enum AdaptiveBackdropMode { cover, extended }

/// 使用物理像素决定画质上限，窗口连续缩放时保留模式滞回。
class AdaptiveBackdropLayout {
  const AdaptiveBackdropLayout({
    required this.mode,
    required this.coverScale,
    required this.visibleFraction,
    required this.foreground,
  });

  final AdaptiveBackdropMode mode;
  final double coverScale, visibleFraction;
  final Rect foreground;
  static const maxSharpScale = 1.04;

  static AdaptiveBackdropLayout calculate({
    required Size image,
    required Size viewport,
    required double devicePixelRatio,
    AdaptiveBackdropMode? previousMode,
  }) {
    assert(image.width > 0 && image.height > 0);
    assert(viewport.width > 0 && viewport.height > 0);
    assert(devicePixelRatio > 0);
    final physical = viewport * devicePixelRatio;
    final coverScale = math.max(
      physical.width / image.width,
      physical.height / image.height,
    );
    final visible =
        physical.width *
        physical.height /
        (image.width * image.height * coverScale * coverScale);
    // 保持裁剪比例滞回，放大始终受清晰度上限约束。
    final minVisible = switch (previousMode) {
      AdaptiveBackdropMode.cover => .66,
      AdaptiveBackdropMode.extended => .74,
      null => .70,
    };
    final maxCover = previousMode == AdaptiveBackdropMode.extended
        ? 1.02
        : maxSharpScale;
    final mode = coverScale <= maxCover && visible >= minVisible
        ? AdaptiveBackdropMode.cover
        : AdaptiveBackdropMode.extended;
    final scale = math.min(
      maxSharpScale,
      math.min(
        physical.width * .97 / image.width,
        physical.height * .97 / image.height,
      ),
    );
    final sharp = image * (scale / devicePixelRatio);
    final right = viewport.width * .025;
    return AdaptiveBackdropLayout(
      mode: mode,
      coverScale: coverScale,
      visibleFraction: visible,
      foreground: Rect.fromLTWH(
        viewport.width - right - sharp.width,
        (viewport.height - sharp.height) / 2,
        sharp.width,
        sharp.height,
      ),
    );
  }
}
