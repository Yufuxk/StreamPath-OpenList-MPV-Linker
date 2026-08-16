import 'package:flutter/material.dart';

/// StreamPath 的轻量页面淡化转场。
///
/// 不缩放页面，也不对页面做模糊、快照或不透明遮罩。
class StreamPathPageTransitionsBuilder extends PageTransitionsBuilder {
  const StreamPathPageTransitionsBuilder();

  @visibleForTesting
  static const incomingFadeKey = Key('streampath-page-incoming-fade');

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
      ) => FadeTransition(
        opacity: Tween<double>(begin: 1, end: 0).animate(
          CurvedAnimation(
            parent: secondaryAnimation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        ),
        child: child,
      );

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext? context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final incomingOpacity = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final outgoingOpacity = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );

    return FadeTransition(
      opacity: outgoingOpacity,
      child: FadeTransition(
        key: StreamPathPageTransitionsBuilder.incomingFadeKey,
        opacity: incomingOpacity,
        child: child,
      ),
    );
  }
}
