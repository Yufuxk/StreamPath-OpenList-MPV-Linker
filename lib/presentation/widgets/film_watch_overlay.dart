import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:ui' as ui;
import 'dart:async';
import '../localization/app_text.dart';
import '../theme/app_theme.dart';

import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_watch_state.dart';
import 'skeleton_scope.dart';
import '../state/app_state.dart';
import 'film_artwork.dart';

const _progressHeight = 4.0;

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
    this.softEdges = false,
    this.revealLabel = '展示剧透',
    this.footer,
    this.hoverSurface = false,
    this.foreground,
    this.onStatusDecoration,
  });
  final Widget child;
  final bool spoilerSensitive, showStatus;
  final bool canReveal;
  final bool revealBelow;

  /// 简介在原槽位中使用柔和渐隐与圆角，不影响揭示按钮位置。
  final bool softEdges;
  final String revealLabel;
  final Widget? footer;

  /// 根据实际遮罩状态选择封面悬停的绘制方式。
  final bool hoverSurface;

  /// 与封面一起运动、无需防剧透模糊的角标和操作。
  final Widget? foreground;
  final ValueChanged<Widget Function(Widget)>? onStatusDecoration;
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
  bool _loaded = false;
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
    value.watchChanges.addListener(_scheduleLoad);
    _load();
  }

  @override
  void didUpdateWidget(FilmWatchOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.store != oldWidget.store && widget.store != null) {
      _store?.watchChanges.removeListener(_scheduleLoad);
      _revealed = false;
      _resolvedResource = null;
      _state = null;
      _loaded = false;
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
      final previous = oldWidget.resource;
      final current = widget.resource;
      final sameEpisode =
          previous != null &&
          current != null &&
          !previous.isDisc &&
          !current.isDisc &&
          previous.type == FilmMediaType.tv &&
          current.type == FilmMediaType.tv &&
          previous.workId != null &&
          previous.workId == current.workId &&
          previous.season != null &&
          previous.season == current.season &&
          previous.episode != null &&
          previous.episode == current.episode;
      // 同一集换资源时保留已显示内容，避免临时遮罩卸载图片子树。
      if (!sameEpisode) {
        _revealed = false;
        _state = null;
        _loaded = false;
      } else if (_state?.status == FilmWatchStatus.watched) {
        _revealed = true;
      }
      _resolvedResource = null;
      _load(preserveReveal: sameEpisode);
    }
  }

  @override
  void dispose() {
    ++_generation;
    _loadTimer?.cancel();
    _store?.watchChanges.removeListener(_scheduleLoad);
    super.dispose();
  }

  Future<void> _load({bool preserveReveal = false}) async {
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
          if (!preserveReveal &&
              _state?.status == FilmWatchStatus.watched &&
              state?.status != FilmWatchStatus.watched) {
            _revealed = false;
            if (_reveals?.value.contains(_contentKey) == true) {
              _reveals!.value = {..._reveals!.value}..remove(_contentKey);
            }
          }
          _state = state;
          _loaded = true;
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
    final fraction = widget.fallbackFraction ?? _state?.fraction;
    final pendingOverview =
        widget.spoilerSensitive &&
        widget.revealBelow &&
        widget.workId != null &&
        (_store?.spoilerProtection ?? false) &&
        !_loaded;
    final blocked =
        widget.spoilerSensitive &&
        !pendingOverview &&
        (_store?.spoilerProtection ?? false) &&
        _state?.status != FilmWatchStatus.watched &&
        !((_reveals?.value.contains(_contentKey) ?? false) || _revealed);
    void reveal() {
      if (_reveals != null) {
        _reveals!.value = {..._reveals!.value, _contentKey};
      } else {
        setState(() => _revealed = true);
      }
    }

    final showProgress =
        widget.showStatus &&
        (widget.fallbackFraction != null
            ? fraction! > 0
            : _state?.status == FilmWatchStatus.inProgress);
    Widget artwork = widget.child;
    if (pendingOverview) {
      // 状态确认前保留简介尺寸，避免露出剧透或临时揭示按钮。
      artwork = Opacity(opacity: 0, child: ExcludeSemantics(child: artwork));
    }
    if (blocked) {
      final softBlur = widget.revealBelow || widget.softEdges;
      artwork = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: softBlur ? 6 : 16,
          sigmaY: softBlur ? 6 : 16,
          tileMode: softBlur ? ui.TileMode.decal : ui.TileMode.clamp,
        ),
        child: ExcludeSemantics(child: artwork),
      );
      if (softBlur) {
        artwork = Opacity(
          opacity: .7,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) {
              final fade = (8 / bounds.height).clamp(0.0, .45);
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: const [
                  Colors.transparent,
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
                stops: [0, fade, 1 - fade, 1],
              ).createShader(bounds);
            },
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) {
                final fade = (12 / bounds.width).clamp(0.0, .45);
                return LinearGradient(
                  colors: const [
                    Colors.transparent,
                    Colors.white,
                    Colors.white,
                    Colors.transparent,
                  ],
                  stops: [0, fade, 1 - fade, 1],
                ).createShader(bounds);
              },
              child: artwork,
            ),
          ),
        );
      }
      artwork = widget.softEdges
          ? ClipRRect(borderRadius: AppTheme.controlRadius, child: artwork)
          : ClipRect(child: artwork);
    }
    final unwatched =
        widget.showStatus && _state?.status == FilmWatchStatus.unwatched;
    final visibleFraction = showProgress ? fraction : null;
    widget.onStatusDecoration?.call(
      _WatchStatusDecoration.snapshot(unwatched, visibleFraction),
    );
    Widget content = _WatchStatusDecoration(
      unwatched: unwatched,
      fraction: visibleFraction,
      reveal: blocked && widget.canReveal && !widget.revealBelow
          ? Positioned.fill(
              child: Center(
                child: TextButton(
                  onPressed: reveal,
                  child: AppText(widget.revealLabel),
                ),
              ),
            )
          : null,
      child: artwork,
    );
    if (widget.foreground != null) {
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          content,
          Positioned.fill(child: widget.foreground!),
        ],
      );
    }
    if (!widget.revealBelow) {
      return widget.hoverSurface
          ? FilmPosterHoverSurface(blurred: blocked, child: content)
          : content;
    }
    return SkeletonLoadBoundary(
      ready: !pendingOverview,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          content,
          if (blocked && widget.canReveal)
            TextButton(onPressed: reveal, child: AppText(widget.revealLabel))
          else if (!blocked && widget.footer != null)
            widget.footer!,
        ],
      ),
    );
  }
}

class _WatchStatusDecoration extends StatelessWidget {
  const _WatchStatusDecoration({
    required this.unwatched,
    required this.fraction,
    required this.child,
    this.reveal,
  });
  final bool unwatched;
  final double? fraction;
  final Widget child;
  final Widget? reveal;

  // 飞行只持有装饰数值，不持有源 State 或重复查询观看状态。
  static Widget Function(Widget) snapshot(bool unwatched, double? fraction) =>
      (child) => _WatchStatusDecoration(
        unwatched: unwatched,
        fraction: fraction,
        child: child,
      );

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      child,
      ?reveal,
      if (unwatched)
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
      if (fraction != null)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: _progressHeight,
              color: Theme.of(context).colorScheme.primary,
              backgroundColor: Colors.transparent,
              borderRadius: BorderRadius.circular(_progressHeight / 2),
              trackGap: 0,
              stopIndicatorRadius: 0,
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
