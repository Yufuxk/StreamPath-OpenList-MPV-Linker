import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/widgets/adaptive_backdrop_layout.dart';

void main() {
  AdaptiveBackdropLayout layout(
    Size image,
    Size viewport, {
    double dpr = 1,
    AdaptiveBackdropMode? previous,
  }) => AdaptiveBackdropLayout.calculate(
    image: image,
    viewport: viewport,
    devicePixelRatio: dpr,
    previousMode: previous,
  );

  test('像素与保留面积共同决定背景模式', () {
    const hd = Size(1920, 1080), uhd = Size(3840, 2160);
    expect(layout(uhd, hd).mode, AdaptiveBackdropMode.cover);
    expect(layout(hd, hd).mode, AdaptiveBackdropMode.cover);
    expect(layout(hd, uhd).mode, AdaptiveBackdropMode.extended);
    expect(
      layout(const Size(1360, 765), hd).mode,
      AdaptiveBackdropMode.extended,
    );
    expect(
      layout(const Size(7680, 1080), hd).mode,
      AdaptiveBackdropMode.extended,
    );
    expect(
      layout(const Size(1080, 1920), hd).mode,
      AdaptiveBackdropMode.extended,
    );
    expect(layout(hd, hd, dpr: 2).mode, AdaptiveBackdropMode.extended);
  });

  test('轻微放大不超过4%，包含连续缩放滞回', () {
    const image = Size(1000, 500);
    expect(
      layout(image, const Size(1039, 519.5)).mode,
      AdaptiveBackdropMode.cover,
    );
    expect(
      layout(
        image,
        const Size(1041, 520.5),
        previous: AdaptiveBackdropMode.cover,
      ).mode,
      AdaptiveBackdropMode.extended,
    );
    expect(
      layout(
        image,
        const Size(1030, 515),
        previous: AdaptiveBackdropMode.extended,
      ).mode,
      AdaptiveBackdropMode.extended,
    );
    expect(
      layout(
        image,
        const Size(1020, 510),
        previous: AdaptiveBackdropMode.extended,
      ).mode,
      AdaptiveBackdropMode.cover,
    );
  });

  test('清晰主体等比缩放且物理像素受限，位置偏右', () {
    for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
      const image = Size(1360, 765), viewport = Size(1920, 1080);
      final result = layout(image, viewport, dpr: dpr);
      expect(
        result.foreground.width * dpr,
        lessThanOrEqualTo(1360 * 1.04 + .001),
      );
      expect(
        result.foreground.width / result.foreground.height,
        closeTo(1360 / 765, .00001),
      );
      expect(result.foreground.right, closeTo(1920 * .975, .0001));
      expect(result.foreground.center.dy, 540);
    }
  });
}
