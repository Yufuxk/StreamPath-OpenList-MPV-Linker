import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:ui' as ui;
import 'dart:async';
import '../localization/app_text.dart';

import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_watch_state.dart';
import '../state/app_state.dart';

class FilmSpoilerScope extends StatefulWidget {
  const FilmSpoilerScope({super.key, required this.child});
  final Widget child;
  @override
  State<FilmSpoilerScope> createState() => _FilmSpoilerScopeState();
}

class _FilmSpoilerScopeState extends State<FilmSpoilerScope> {
  final reveals = ValueNotifier<Set<String>>({});
  @override
  void dispose() {
    reveals.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _FilmSpoilerReveals(notifier: reveals, child: widget.child);
}

class _FilmSpoilerReveals
    extends InheritedNotifier<ValueNotifier<Set<String>>> {
  const _FilmSpoilerReveals({required super.notifier, required super.child});
}

/// 复用观看标记和按内容身份共享的防剧透状态。
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
    this.spoilerSensitive = false,
    this.showStatus = true,
    this.canReveal = true,
    this.revealBelow = false,
    this.revealLabel = '展示剧透',
    this.footer,
  });
  final Widget child;
  final bool spoilerSensitive, showStatus;
  final bool canReveal;
  final bool revealBelow;
  final String revealLabel;
  final Widget? footer;
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
  FilmResource? _resolvedResource;
  int _generation = 0;
  Timer? _loadTimer;
  int _loads = 0;
  bool _reloadPending = false;
  bool _revealed = false;
  ValueNotifier<Set<String>>? _reveals;
  String get _contentKey {
    final resource = widget.resource ?? _resolvedResource;
    return '${widget.workId ?? resource?.workId}:${resource?.type == FilmMediaType.movie ? null : resource?.season ?? widget.season}:${resource?.type == FilmMediaType.movie ? null : resource?.episode}';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reveals = context
        .dependOnInheritedWidgetOfExactType<_FilmSpoilerReveals>()
        ?.notifier;
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
    value.addListener(_scheduleLoad);
    _load();
  }

  @override
  void didUpdateWidget(FilmWatchOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.store != oldWidget.store && widget.store != null) {
      _store?.removeListener(_scheduleLoad);
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
      _revealed = false;
      _state = null;
      _resolvedResource = null;
      _load();
    }
  }

  @override
  void dispose() {
    ++_generation;
    _loadTimer?.cancel();
    _store?.removeListener(_scheduleLoad);
    super.dispose();
  }

  Future<void> _load() async {
    final store = _store;
    if (store == null) return;
    _loads++;
    try {
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
      if (mounted && generation == _generation) {
        setState(() {
          _resolvedResource = resource;
          if (_state?.status == FilmWatchStatus.watched &&
              state?.status != FilmWatchStatus.watched) {
            _revealed = false;
            if (_reveals?.value.contains(_contentKey) == true) {
              _reveals!.value = {..._reveals!.value}..remove(_contentKey);
            }
          }
          _state = state;
        });
      }
    } finally {
      if (--_loads == 0 && _reloadPending && mounted) {
        _reloadPending = false;
        _scheduleLoad();
      }
    }
  }

  void _scheduleLoad() {
    if (_loads > 0) {
      _reloadPending = true;
      return;
    }
    if (_loadTimer?.isActive == true) return;
    _loadTimer = Timer(Duration.zero, _load);
  }

  @override
  Widget build(BuildContext context) {
    final blocked =
        widget.spoilerSensitive &&
        (_store?.spoilerProtection ?? false) &&
        _state?.status != FilmWatchStatus.watched &&
        !(_reveals?.value.contains(_contentKey) ?? _revealed);
    void reveal() {
      if (_reveals != null) {
        _reveals!.value = {..._reveals!.value, _contentKey};
      } else {
        setState(() => _revealed = true);
      }
    }

    final content = Stack(
      children: [
        if (blocked)
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: ExcludeSemantics(child: widget.child),
          )
        else
          widget.child,
        if (blocked && widget.canReveal && !widget.revealBelow)
          Positioned.fill(
            child: Center(
              child: TextButton(
                onPressed: reveal,
                child: AppText(widget.revealLabel),
              ),
            ),
          ),
        if (widget.showStatus && _state?.status == FilmWatchStatus.unwatched)
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
        if (widget.showStatus &&
            (_state?.status == FilmWatchStatus.inProgress ||
                _state == null && (widget.fallbackFraction ?? 0) > 0))
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
    if (!widget.revealBelow) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        content,
        if (blocked && widget.canReveal)
          TextButton(onPressed: reveal, child: AppText(widget.revealLabel))
        else if (!blocked && widget.footer != null)
          widget.footer!,
      ],
    );
  }
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
