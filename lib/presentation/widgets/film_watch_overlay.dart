import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_watch_state.dart';
import '../state/app_state.dart';

/// 只覆盖影片封面，演员与背景图片沿用原显示。
class FilmWatchOverlay extends StatefulWidget {
  const FilmWatchOverlay({
    super.key,
    required this.child,
    this.store,
    this.workId,
    this.rootId,
    this.sourceIds,
    this.season,
    this.resource,
    this.sourceId,
    this.path,
    this.fallbackFraction,
  });
  final Widget child;
  final double? fallbackFraction;
  final FilmCatalogStore? store;
  final int? workId, season, rootId;
  final Set<String>? sourceIds;
  final FilmResource? resource;
  final String? sourceId, path;
  @override
  State<FilmWatchOverlay> createState() => _FilmWatchOverlayState();
}

class _FilmWatchOverlayState extends State<FilmWatchOverlay> {
  FilmCatalogStore? _store;
  FilmWatchState? _state;
  int _generation = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_store != null) return;
    final store = widget.store;
    if (store != null) {
      _bind(store);
      return;
    }
    final app = Provider.of<AppState?>(context, listen: false);
    app?.getFilmCatalogStore().then((value) {
      if (mounted) _bind(value);
    });
  }

  void _bind(FilmCatalogStore value) {
    _store = value;
    value.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(FilmWatchOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.store != oldWidget.store && widget.store != null) {
      _store?.removeListener(_load);
      _bind(widget.store!);
      return;
    }
    if (widget.rootId != oldWidget.rootId ||
        !setEquals(widget.sourceIds, oldWidget.sourceIds) ||
        widget.workId != oldWidget.workId ||
        widget.season != oldWidget.season ||
        widget.resource?.id != oldWidget.resource?.id ||
        widget.resource?.bindingVersion != oldWidget.resource?.bindingVersion ||
        widget.sourceId != oldWidget.sourceId ||
        widget.path != oldWidget.path) {
      _load();
    }
  }

  @override
  void dispose() {
    ++_generation;
    _store?.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final store = _store;
    if (store == null) return;
    final generation = ++_generation;
    FilmWatchState? state;
    final resource =
        widget.resource ??
        (widget.sourceId != null && widget.path != null
            ? await store.resourceAt(widget.sourceId!, widget.path!)
            : null);
    if (resource != null) {
      state = await store.resourceWatchState(resource);
    } else if (widget.workId != null) {
      state = widget.season == null
          ? (await store.workWatchStates(
              [widget.workId!],
              rootId: widget.rootId,
              sourceIds: widget.sourceIds,
            ))[widget.workId!]
          : await store.seasonWatchState(
              widget.workId!,
              widget.season!,
              rootId: widget.rootId,
            );
    }
    if (mounted && generation == _generation) setState(() => _state = state);
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      if (_state?.status == FilmWatchStatus.unwatched)
        Positioned(
          top: 0,
          right: 0,
          child: IgnorePointer(
            child: CustomPaint(
              size: const Size(28, 28),
              painter: _UnwatchedCorner(),
            ),
          ),
        ),
      if (_state?.status == FilmWatchStatus.inProgress ||
          _state == null && (widget.fallbackFraction ?? 0) > 0)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: LinearProgressIndicator(
              value: _state?.fraction ?? widget.fallbackFraction,
              minHeight: 4,
            ),
          ),
        ),
    ],
  );
}

class _UnwatchedCorner extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..close(),
    Paint()..color = const Color(0xFFFF9500),
  );
  @override
  bool shouldRepaint(_UnwatchedCorner oldDelegate) => false;
}
