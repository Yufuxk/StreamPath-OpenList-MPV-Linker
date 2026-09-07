import 'package:flutter/material.dart';

import '../../core/utils/expiring_lru_cache.dart';

/// WebDAV 与本地目录共用的页面内滚动位置状态。
class DirectoryScrollState {
  DirectoryScrollState({
    required int maxEntries,
    required Duration idleTtl,
    Duration Function()? idleTtlProvider,
  }) : _positions = ExpiringLruCache(
         maxEntries: maxEntries,
         idleTtl: idleTtl,
         idleTtlProvider: idleTtlProvider,
       );

  final ScrollController controller = ScrollController(keepScrollOffset: false);
  final ExpiringLruCache<String, double> _positions;

  void remember(String key) {
    if (!controller.hasClients) return;
    _positions.write(key, controller.offset);
  }

  void scheduleRestore({
    required String key,
    required bool Function() isCurrent,
  }) {
    final target = _positions.read(key) ?? 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isCurrent() || !controller.hasClients) return;
      final position = controller.position;
      final offset = target
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((position.pixels - offset).abs() > 0.5) {
        controller.jumpTo(offset);
      }
    });
  }

  void dispose() => controller.dispose();
}
