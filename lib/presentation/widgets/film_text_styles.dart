import 'package:flutter/material.dart';

/// 影视背景上的共享文字样式。
abstract final class FilmTextStyles {
  static const shadows = [
    Shadow(color: Color(0xCC000000), offset: Offset(0, 1), blurRadius: 3),
    Shadow(color: Color(0x80000000), offset: Offset(0, 2), blurRadius: 8),
  ];

  static const overviewMaxWidth = 620.0;
  static final overview = TextStyle(
    fontSize: 15,
    height: 1.75,
    color: Colors.white.withValues(alpha: .82),
    shadows: shadows,
  );
}
