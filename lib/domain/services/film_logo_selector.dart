import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Logo 色彩评分：Hasler-Süsstrunk 色彩丰富度 + HSV 明度/饱和度分布。
class LogoColorScore {
  const LogoColorScore({
    required this.colorfulness,
    required this.lightShare,
    required this.heavyShare,
    required this.meanValue,
  });

  final double colorfulness;
  final double lightShare;
  final double heavyShare;
  final double meanValue;

  /// 亮色、色彩丰富且分辨率足够的候选优先；深色或高饱和的厚重候选靠后。
  double get rank =>
      (colorfulness / 160).clamp(0.0, 1.0) * .30 +
      meanValue * .25 +
      (lightShare - heavyShare) * .15;
}

/// 单枚候选的综合得分：色彩评分七成、分辨率三成，再叠加语言偏好加分。
double logoChoiceRank(LogoColorScore score, int width, int priority) =>
    score.rank +
    (width / 1000).clamp(0.0, 1.0) * .30 +
    _languageBonus[priority.clamp(0, _languageBonus.length - 1)];

/// 语言偏好：原产地 > 中文 > 英文 > 其他国家。
const _languageBonus = [.18, .12, .06, 0.0];

/// 候选 Logo 的路径、原始宽度与语言偏好层级；宽度用于排除低分辨率版本。
class LogoChoice {
  const LogoChoice(this.path, this.width, this.priority);
  final String path;
  final int width;
  final int priority;
}

/// 统计可见像素的对立色通道与明度/饱和度占比，供 isolate 调用。
LogoColorScore analyzeLogoColor(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('invalid logo');
  final image = decoded.convert(numChannels: 4);
  final data = image.getBytes(order: img.ChannelOrder.rgba);
  var count = 0;
  var sumRg = 0.0, sumYb = 0.0, sumRg2 = 0.0, sumYb2 = 0.0, sumValue = 0.0;
  var light = 0, heavy = 0;
  for (var i = 0; i < data.length; i += 4) {
    final alpha = data[i + 3];
    if (alpha <= 8) continue;
    final r = data[i].toDouble();
    final g = data[i + 1].toDouble();
    final b = data[i + 2].toDouble();
    final rg = r - g;
    final yb = .5 * (r + g) - b;
    sumRg += rg;
    sumYb += yb;
    sumRg2 += rg * rg;
    sumYb2 += yb * yb;
    final high = math.max(r, math.max(g, b));
    final low = math.min(r, math.min(g, b));
    final value = high / 255;
    sumValue += value;
    final saturation = high == 0 ? 0.0 : (high - low) / high;
    if (value > .7 && saturation > .1 && saturation < .6) light++;
    if (value < .3 || saturation > .8) heavy++;
    count++;
  }
  if (count == 0) throw const FormatException('transparent logo');
  final meanRg = sumRg / count, meanYb = sumYb / count;
  final varianceRg = math.max(0.0, sumRg2 / count - meanRg * meanRg);
  final varianceYb = math.max(0.0, sumYb2 / count - meanYb * meanYb);
  return LogoColorScore(
    colorfulness:
        math.sqrt(varianceRg + varianceYb) +
        .3 * math.sqrt(meanRg * meanRg + meanYb * meanYb),
    lightShare: light / count,
    heavyShare: heavy / count,
    meanValue: sumValue / count,
  );
}

/// 在候选 Logo 中选出色彩/明度/分辨率更好、且语言偏好更高的版本；单候选失败时跳过。
Future<String?> selectBestLogo(
  List<LogoChoice> candidates, {
  required Future<Uint8List> Function(String path) read,
}) async {
  if (candidates.length < 2) return candidates.firstOrNull?.path;
  String? best;
  var bestRank = double.negativeInfinity;
  for (final candidate in candidates.take(6)) {
    try {
      final score = await compute(analyzeLogoColor, await read(candidate.path));
      final rank = logoChoiceRank(score, candidate.width, candidate.priority);
      if (rank > bestRank) {
        bestRank = rank;
        best = candidate.path;
      }
    } on Exception {
      // 下载或解码失败的候选不参与比较，其余候选继续。
    }
  }
  return best;
}
