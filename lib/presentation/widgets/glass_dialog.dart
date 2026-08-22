import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/glass_tokens.dart';

/// 显示带单层背景模糊的对话框，默认样式仍使用标准 Material 路由。
Future<T?> showGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
}) {
  final tokens = Theme.of(context).glass;
  if (!tokens.enabled) {
    return showDialog<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      useRootNavigator: useRootNavigator,
    );
  }

  final barrierLabel = MaterialLocalizations.of(
    context,
  ).modalBarrierDismissLabel;

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    barrierColor: Colors.transparent,
    useRootNavigator: useRootNavigator,
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (dialogContext, animation, secondaryAnimation) =>
        _GlassDialogTransition(
          animation: animation,
          tokens: tokens,
          child: builder(dialogContext),
        ),
    transitionBuilder: (context, animation, secondaryAnimation, child) => child,
  );
}

class _GlassDialogTransition extends StatelessWidget {
  const _GlassDialogTransition({
    required this.animation,
    required this.tokens,
    required this.child,
  });

  final Animation<double> animation;
  final GlassTokens tokens;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final backdropProgress = Curves.easeInOutSine.transform(
          animation.value.clamp(0.0, 1.0),
        );
        final dialogProgress = _curveProgress(
          animation.value,
          forward: Curves.easeOutCubic,
          reverse: Curves.easeInCubic,
        );
        final scale =
            tokens.modalScaleBegin +
            (1 - tokens.modalScaleBegin) * dialogProgress;
        final offsetY = tokens.modalSlideOffset * (1 - dialogProgress);

        return Stack(
          fit: StackFit.expand,
          children: [
            GlassDialogBackdrop(
              key: const Key('glass-dialog-backdrop'),
              progress: backdropProgress,
              tokens: tokens,
            ),
            Opacity(
              opacity: dialogProgress,
              child: Transform.translate(
                offset: Offset(0, offsetY),
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.center,
                  child: child,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  double _curveProgress(
    double value, {
    required Curve forward,
    required Curve reverse,
  }) {
    final curve = animation.status == AnimationStatus.reverse
        ? reverse
        : forward;
    return curve.transform(value.clamp(0.0, 1.0));
  }
}

/// 模态层背景只创建一层逐帧变化的模糊，避免完整模糊在首帧突入。
class GlassDialogBackdrop extends StatelessWidget {
  const GlassDialogBackdrop({
    super.key,
    required this.progress,
    required this.tokens,
  });

  final double progress;
  final GlassTokens tokens;

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0.0, 1.0);
    final sigma = tokens.modalBlurSigma * value;
    final barrierColor = Color.lerp(
      Colors.transparent,
      tokens.modalBarrierColor,
      value,
    )!;

    return IgnorePointer(
      child: BackdropFilter(
        key: const Key('glass-dialog-backdrop-filter'),
        filter: ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.clamp,
        ),
        child: ColoredBox(
          key: const Key('glass-dialog-barrier-color'),
          color: barrierColor,
        ),
      ),
    );
  }
}
