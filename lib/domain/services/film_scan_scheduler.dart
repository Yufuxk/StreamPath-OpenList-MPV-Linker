import 'dart:async';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';

/// 应用内调度；错过多个周期只执行一轮，忙碌时保持到期状态。
class FilmScanScheduler {
  FilmScanScheduler({
    required this.store,
    required this.isBusy,
    required this.scan,
  });
  final FilmCatalogStore store;
  final Future<bool> Function() isBusy;
  final Future<void> Function(List<FilmCatalogRoot>) scan;
  Timer? _timer;
  Future<void>? _running;
  bool _closed = false;
  void start() {
    if (_closed || _timer != null) return;
    _timer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(tick()),
    );
    unawaited(tick());
  }

  Future<void> tick({DateTime? now}) async {
    if (_closed || _running != null) return;
    final task = _tick(now ?? DateTime.now());
    _running = task;
    try {
      await task;
    } finally {
      _running = null;
    }
  }

  Future<void> _tick(DateTime now) async {
    if (await store.preference('scan_enabled') == false) return;
    final hours =
        ((await store.preference('scan_interval_hours') as int?) ?? 24).clamp(
          6,
          8760,
        );
    final last = await store.preference('scan_last_attempt') as int?;
    if (last == null) {
      await store.setPreference(
        'scan_last_attempt',
        now.millisecondsSinceEpoch,
      );
      return;
    }
    if (now.millisecondsSinceEpoch - last <
        Duration(hours: hours).inMilliseconds) {
      return;
    }
    if (_closed || await isBusy()) return;
    final roots = <FilmCatalogRoot>[];
    for (final root in await store.roots()) {
      if (root.enabled &&
          await store.preference('root_enabled:${root.id}') != false) {
        roots.add(root);
      }
    }
    if (_closed) return;
    await store.setPreference('scan_last_attempt', now.millisecondsSinceEpoch);
    await scan(roots);
  }

  Future<void> close() async {
    stop();
    await _running;
  }

  void stop() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}
