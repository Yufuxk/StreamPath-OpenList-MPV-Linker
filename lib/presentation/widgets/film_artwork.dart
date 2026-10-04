import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/models/film_catalog_item.dart';
import '../../domain/services/film_catalog_image_cache.dart';
import '../localization/app_localizations.dart';
import 'sp_icons.dart';

ImageProvider<Object> filmArtworkProvider(
  File file, {
  String target = 'w342',
  bool backdrop = false,
  double devicePixelRatio = 1,
}) => ResizeImage.resizeIfNeeded(
  backdrop || target == 'original' ? null : int.parse(target.substring(1)),
  null,
  FileImage(file, scale: backdrop ? devicePixelRatio : 1),
);

final _detailPrecaches = Expando<_FilmDetailPrecache>();

/// 预热与导航并行；每个图片缓存只解码当前候选，排队时保留最新候选。
void precacheFilmDetailArtwork(
  BuildContext context,
  FilmCatalogImageCache cache,
  FilmWork work,
) {
  final precache = _detailPrecaches[cache] ??= _FilmDetailPrecache(cache);
  precache.schedule(context, work);
}

class _FilmDetailPrecache {
  _FilmDetailPrecache(this.cache);
  final FilmCatalogImageCache cache;
  (BuildContext, FilmWork, double)? _next;
  (String?, String?, double)? _current;
  bool _running = false;

  void schedule(BuildContext context, FilmWork work) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (_current == (work.backdropPath, work.posterPath, dpr)) {
      _next = null;
      return;
    }
    _next = (context, work, dpr);
    if (!_running) unawaited(_run());
  }

  Future<void> _run() async {
    _running = true;
    try {
      while (_next != null) {
        final (context, work, dpr) = _next!;
        _next = null;
        _current = (work.backdropPath, work.posterPath, dpr);
        for (final (path, target, backdrop) in [
          (work.backdropPath, 'original', true),
          (work.posterPath, 'w500', false),
        ]) {
          if (path == null || !context.mounted) continue;
          // 预热仅访问本地缓存，缺失图片仍由原展示链路处理。
          var file = await cache.cached(path, target);
          if (file == null && backdrop) file = await cache.cached(path, 'w780');
          if (file == null || !context.mounted) continue;
          await precacheImage(
            filmArtworkProvider(
              file,
              target: target,
              backdrop: backdrop,
              devicePixelRatio: dpr,
            ),
            context,
            onError: (error, _) =>
                debugPrint('Film artwork precache failed: $error'),
          );
        }
      }
    } on FilmCatalogException catch (error) {
      debugPrint('Film artwork precache failed: ${error.code}');
    } on FileSystemException catch (error) {
      debugPrint('Film artwork precache failed: ${error.osError}');
    } finally {
      _next = null;
      _current = null;
      _running = false;
    }
  }
}

class FilmArtwork extends StatefulWidget {
  const FilmArtwork({
    super.key,
    required this.cache,
    required this.path,
    this.target = 'w342',
    this.width,
    this.height,
    this.aspectRatio,
    this.borderRadius = 8,
    this.placeholder,
    this.backdrop = false,
    this.transparent = false,
    this.fallbackPath,
  });
  final FilmCatalogImageCache cache;
  final String? path;
  final String target;
  final double? width;
  final double? height;
  final double? aspectRatio;
  final double borderRadius;
  final Widget? placeholder;
  final bool backdrop;
  final bool transparent;
  final String? fallbackPath;
  @override
  State<FilmArtwork> createState() => _FilmArtworkState();
}

class _FilmArtworkState extends State<FilmArtwork> {
  Future<File>? _image;
  void _load() => _image = widget.path == null
      ? null
      : widget.backdrop
      ? _loadBackdrop()
      : widget.cache.get(widget.path!, target: widget.target);

  Future<File> _loadBackdrop() async {
    final path = widget.path!;
    try {
      return await widget.cache.get(path, target: widget.target);
    } on FilmCatalogException {
      // 离线或原图请求失败时复用已缓存背景，不额外下载缩略图。
      final cached = await widget.cache.cached(path, 'w780');
      if (cached != null) return cached;
      rethrow;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FilmArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache ||
        oldWidget.path != widget.path ||
        oldWidget.target != widget.target ||
        oldWidget.backdrop != widget.backdrop) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final artwork = ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: ColoredBox(
        color: widget.transparent
            ? Colors.transparent
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        child: FutureBuilder<File>(
          key: ValueKey((
            widget.cache,
            widget.path,
            widget.target,
            widget.backdrop,
          )),
          future: _image,
          initialData:
              widget.cache.knownFile(widget.path, widget.target) ??
              (widget.backdrop
                  ? widget.cache.knownFile(widget.path, 'w780')
                  : null),
          builder: (context, state) {
            final fallback = state.hasError ? null : _readyFallback();
            if (state.hasData || fallback != null) {
              final provider = state.hasData
                  ? filmArtworkProvider(
                      state.data!,
                      target: widget.target,
                      backdrop: widget.backdrop,
                      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                    )
                  : fallback!;
              if (widget.backdrop) {
                return RepaintBoundary(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: 28,
                          sigmaY: 28,
                          tileMode: ui.TileMode.clamp,
                        ),
                        child: _renderImage(
                          provider,
                          fallback: fallback,
                          fit: BoxFit.cover,
                        ),
                      ),
                      ColoredBox(color: Colors.black.withValues(alpha: .38)),
                      // 羽化只覆盖原图边缘，中心保持完整构图与原始像素上限。
                      Center(
                        child: ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (bounds) {
                            final fade = (64 / bounds.width).clamp(0.0, .12);
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
                          child: ShaderMask(
                            blendMode: BlendMode.dstIn,
                            shaderCallback: (bounds) {
                              final fade = (64 / bounds.height).clamp(0.0, .12);
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
                            child: _renderImage(
                              provider,
                              fallback: fallback,
                              fit: BoxFit.scaleDown,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return _renderImage(
                provider,
                fallback: fallback,
                fit: widget.transparent ? BoxFit.contain : BoxFit.cover,
                alignment: widget.transparent
                    ? Alignment.centerLeft
                    : Alignment.center,
              );
            }
            return _placeholder(retry: state.hasError);
          },
        ),
      ),
    );
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: widget.height != null
          ? artwork
          : AspectRatio(
              aspectRatio:
                  widget.aspectRatio ??
                  (widget.target == 'w780' ? 16 / 9 : 2 / 3),
              child: artwork,
            ),
    );
  }

  ImageProvider<Object>? _readyFallback() {
    final file = widget.cache.knownFile(widget.fallbackPath, 'w342');
    if (file == null) return null;
    final provider = filmArtworkProvider(file);
    // FileImage 和 ResizeImage 的缓存键均同步返回。
    late ImageCacheStatus status;
    provider.obtainKey(ImageConfiguration.empty).then((key) {
      status = PaintingBinding.instance.imageCache.statusForKey(key);
    });
    return !status.pending && (status.keepAlive || status.live)
        ? provider
        : null;
  }

  Widget _renderImage(
    ImageProvider<Object> provider, {
    ImageProvider<Object>? fallback,
    required BoxFit fit,
    Alignment alignment = Alignment.center,
    FilterQuality filterQuality = FilterQuality.medium,
  }) => Image(
    image: provider,
    fit: fit,
    alignment: alignment,
    filterQuality: filterQuality,
    frameBuilder: fallback == null
        ? null
        : (_, child, frame, _) => frame != null
              ? child
              : Image(
                  image: fallback,
                  fit: fit,
                  alignment: alignment,
                  filterQuality: filterQuality,
                ),
    errorBuilder: (_, _, _) => _placeholder(retry: true),
  );

  Widget _placeholder({bool retry = false}) => Center(
    child:
        widget.placeholder ??
        (retry
            ? IconButton(
                onPressed: () => setState(_load),
                icon: const Icon(SPIcons.refresh),
                tooltip: context.l10n.text('重试图片'),
              )
            : const Icon(SPIcons.video, size: 32)),
  );
}
