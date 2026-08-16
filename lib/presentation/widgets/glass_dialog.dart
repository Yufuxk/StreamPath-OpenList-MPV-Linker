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
  final barrierColor = Colors.black.withValues(alpha: 0.18);

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    barrierColor: Colors.transparent,
    useRootNavigator: useRootNavigator,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, animation, secondaryAnimation) => Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: tokens.modalBlurSigma,
              sigmaY: tokens.modalBlurSigma,
            ),
            child: ColoredBox(color: barrierColor),
          ),
        ),
        builder(dialogContext),
      ],
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
          child: child,
        ),
  );
}
