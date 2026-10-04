import 'dart:io';

import 'package:flutter/material.dart';

import 'film_artwork.dart';

class FilmLibraryBackground extends StatelessWidget {
  const FilmLibraryBackground({super.key, required this.file});
  final File? file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.scaffoldBackgroundColor.withValues(alpha: 1);
    final dark = theme.brightness == Brightness.dark;
    final backdrop = file;
    if (backdrop == null) {
      return ColoredBox(
        key: const Key('film-library-background'),
        color: theme.scaffoldBackgroundColor,
      );
    }
    return Stack(
      key: const Key('film-library-background'),
      fit: StackFit.expand,
      children: [
        ColoredBox(color: base),
        Image(
          key: ValueKey(backdrop.path),
          image: filmArtworkProvider(backdrop, target: 'original'),
          // 返回页面时保留当前图片，实际切换背景由路径 key 重建。
          gaplessPlayback: true,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                base.withValues(alpha: dark ? .90 : .96),
                base.withValues(alpha: dark ? .58 : .78),
                base.withValues(alpha: dark ? .36 : .66),
              ],
              stops: const [0, .48, 1],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                base.withValues(alpha: .10),
                base.withValues(alpha: .64),
                base,
              ],
              stops: const [0, .62, 1],
            ),
          ),
        ),
      ],
    );
  }
}
