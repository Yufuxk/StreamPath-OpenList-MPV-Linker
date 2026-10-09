import 'package:flutter/material.dart';

/// 相邻横向移动页面，避免半透明内容重叠。
class StreamPathPageTransitionsBuilder extends PageTransitionsBuilder {
  const StreamPathPageTransitionsBuilder();

  @visibleForTesting
  static const incomingSlideKey = Key('streampath-page-incoming-slide');

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 180);

  @override
  DelegatedTransitionBuilder get delegatedTransition =>
      (
        BuildContext context,
        Animation<double> animation,
        Animation<double> secondaryAnimation,
        bool allowSnapshotting,
        Widget? child,
      ) => _slideOut(secondaryAnimation, child);

  static Widget _slideOut(Animation<double> animation, Widget? child) =>
      ClipRect(
        child: SlideTransition(
          position: Tween<Offset>(begin: Offset.zero, end: const Offset(-1, 0))
              .animate(
                CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                ),
              ),
          child: child,
        ),
      );

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext? context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final progress = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return _slideOut(
      secondaryAnimation,
      ClipRect(
        child: SlideTransition(
          key: StreamPathPageTransitionsBuilder.incomingSlideKey,
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(progress),
          child: child,
        ),
      ),
    );
  }
}
