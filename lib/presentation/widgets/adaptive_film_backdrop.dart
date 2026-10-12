import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../domain/services/film_catalog_image_cache.dart';
import 'adaptive_backdrop_layout.dart';
import 'film_artwork.dart';
import 'film_watch_overlay.dart';
import 'film_adaptive_foreground.dart';
import 'transition_content.dart';

enum FilmBackdropStyle { detail, library, showcase }

/// 全窗口背景共用原图像素上限、预模糊补边与有界切图动画。
class AdaptiveFilmBackdrop extends StatefulWidget {
  const AdaptiveFilmBackdrop({
    super.key,
    required this.cache,
    this.path,
    this.file,
    this.style = FilmBackdropStyle.detail,
    this.onReady,
    this.onImageReady,
    this.watchStore,
    this.workId,
    this.textColors,
  }) : assert(path == null || file == null);

  final FilmCatalogImageCache cache;
  final String? path;
  final File? file;
  final FilmBackdropStyle style;
  final VoidCallback? onReady;
  final VoidCallback? onImageReady;
  final FilmCatalogStore? watchStore;
  final int? workId;
  final FilmBackdropTextController? textColors;

  @override
  State<AdaptiveFilmBackdrop> createState() => _AdaptiveFilmBackdropState();
}

class _AdaptiveFilmBackdropState extends State<AdaptiveFilmBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _transition;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  _BackdropFrame? _current, _previous;
  int _generation = 0;
  double? _dpr;
  AdaptiveBackdropLayout? _layout;
  (Size, Size, double)? _layoutInputs;
  bool _moving = false, _loadPending = false;
  (ImageProvider<Object>, int)? _pendingCommit;
  Object? _samplingInputs;

  @override
  void initState() {
    super.initState();
    _transition =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
          value: 1,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && _previous != null) {
            setState(() {
              _previous!.info.dispose();
              _previous = null;
            });
          }
        });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _samplingInputs = null;
    final moving = StreamPathTransitionScope.of(context);
    if (moving != _moving) {
      _moving = moving;
      if (moving) {
        _transition.stop();
        if (_stream != null || _current == null) {
          _generation++;
          _stopStream();
          _loadPending = true;
        }
      } else {
        if (_loadPending) _load();
        if (_previous != null) _transition.forward();
      }
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (_dpr != dpr) {
      _dpr = dpr;
      _load();
    }
  }

  @override
  void didUpdateWidget(AdaptiveFilmBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache ||
        oldWidget.path != widget.path ||
        oldWidget.file?.path != widget.file?.path) {
      if (oldWidget.cache != widget.cache) _clearFrames();
      _load();
    }
  }

  void _stopStream() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  void _clearFrames() {
    _transition.stop();
    _current?.info.dispose();
    _previous?.info.dispose();
    _current = _previous = null;
    _layout = null;
    _layoutInputs = null;
  }

  void _load() {
    if (_moving) {
      _generation++;
      _stopStream();
      _loadPending = true;
      return;
    }
    _loadPending = false;
    final generation = ++_generation;
    _stopStream();
    if (_current != null && _current!.blur == null) {
      _current!.blurRequested = false;
    }
    final path = widget.path;
    final file = widget.file;
    if (file == null && path == null) {
      _clearFrames();
      return;
    }
    if (file != null) {
      _resolve(file, generation);
      return;
    }
    final known =
        widget.cache.knownFile(path, 'original') ??
        widget.cache.knownFile(path, 'w780');
    if (known != null) {
      _resolve(known, generation);
    }
    unawaited(_loadPath(path!, generation));
  }

  Future<void> _loadPath(String path, int generation) async {
    try {
      File file;
      try {
        file = await widget.cache.get(path, target: 'original');
      } on FilmCatalogException {
        final cached = await widget.cache.cached(path, 'w780');
        if (cached == null) rethrow;
        file = cached;
      }
      if (mounted && generation == _generation) _resolve(file, generation);
    } on FilmCatalogException catch (error) {
      if (mounted && generation == _generation) _failed(error.code);
    } on FileSystemException catch (error) {
      if (mounted && generation == _generation) {
        _failed(error.osError?.errorCode);
      }
    }
  }

  void _failed(Object? code) {
    debugPrint('Film backdrop load failed: $code');
    widget.onReady?.call();
  }

  void _resolve(File file, int generation, {ImageProvider<Object>? provider}) {
    if (_moving) {
      _loadPending = true;
      return;
    }
    final thumbnailPath = provider == null ? widget.path : null;
    provider ??= filmArtworkProvider(
      file,
      target: 'original',
      backdrop: true,
      devicePixelRatio: _dpr!,
    );
    if (_current?.provider == provider ||
        _pendingCommit == (provider, generation)) {
      return;
    }
    _stopStream();
    final stream = _stream = provider.resolve(
      createLocalImageConfiguration(context),
    );
    final resolvedProvider = provider;
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, synchronous) {
        stream.removeListener(listener);
        if (_listener == listener) {
          _stream = null;
          _listener = null;
        }
        if (!mounted || generation != _generation) {
          info.dispose();
          return;
        }
        if (_moving) {
          info.dispose();
          _loadPending = true;
          return;
        }
        void commit() => _commitFrame(
          file,
          resolvedProvider,
          info,
          thumbnailPath,
          generation,
        );
        // 同步命中首张图时，背景与橱窗前景一起在下一帧提交。
        if (_current == null &&
            widget.onImageReady != null &&
            SchedulerBinding.instance.schedulerPhase ==
                SchedulerPhase.persistentCallbacks) {
          _pendingCommit = (resolvedProvider, generation);
          WidgetsBinding.instance.addPostFrameCallback((_) => commit());
        } else {
          commit();
        }
      },
      onError: (Object error, StackTrace? stack) {
        stream.removeListener(listener);
        if (mounted && generation == _generation) {
          // 同一文件失效时释放已显示内容；新候选失败仍保留原背景。
          if (_current?.file.path == file.path) setState(_clearFrames);
          _failed(error.runtimeType);
        }
      },
    );
    _listener = listener;
    stream.addListener(listener);
  }

  void _commitFrame(
    File file,
    ImageProvider<Object> provider,
    ImageInfo info,
    String? thumbnailPath,
    int generation,
  ) {
    if (_pendingCommit == (provider, generation)) _pendingCommit = null;
    if (!mounted || generation != _generation || _moving) {
      info.dispose();
      if (mounted && generation == _generation && _moving) _loadPending = true;
      return;
    }
    setState(() {
      _previous?.info.dispose();
      _previous = _current;
      _current = _BackdropFrame(file, provider, info, thumbnailPath);
      _layout = null;
      _layoutInputs = null;
      if (_previous == null) {
        _transition.value = 1;
      } else {
        _transition.forward(from: 0);
      }
    });
    widget.onReady?.call();
    widget.onImageReady?.call();
  }

  void _scheduleBlur(_BackdropFrame frame) {
    if (_moving || frame.blurRequested) return;
    frame.blurRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _current != frame) return;
      if (_layout?.mode != AdaptiveBackdropMode.extended) {
        frame.blurRequested = false;
        return;
      }
      if (_moving) {
        frame.blurRequested = false;
        return;
      }
      unawaited(_prepareBlur(frame));
    });
  }

  Future<void> _prepareBlur(_BackdropFrame frame) async {
    final generation = _generation;
    try {
      final thumbnail = frame.thumbnailPath == null
          ? null
          : await widget.cache.cached(frame.thumbnailPath!, 'w780');
      if (!mounted || generation != _generation || _current != frame) return;
      if (_moving) {
        frame.blurRequested = false;
        return;
      }
      final blur = await widget.cache.backdropBlurs.get(
        frame.file,
        thumbnail: thumbnail,
      );
      if (mounted &&
          generation == _generation &&
          _current == frame &&
          blur != null) {
        if (_moving) {
          frame.blurRequested = false;
          return;
        }
        setState(() => frame.blur = blur);
      }
    } on FileSystemException catch (error) {
      debugPrint(
        'Film backdrop preparation failed: ${error.osError?.errorCode}',
      );
    } on FilmCatalogException catch (error) {
      debugPrint('Film backdrop preparation failed: ${error.code}');
    }
  }

  @override
  void dispose() {
    _generation++;
    _stopStream();
    _clearFrames();
    _transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: IgnorePointer(
      child: _sampleBoundary(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewport = constraints.biggest;
            final theme = Theme.of(context);
            final surface = theme.scaffoldBackgroundColor;
            final frame = _current;
            final samplingInputs = (
              frame,
              _previous,
              frame?.blur,
              viewport,
              surface,
              theme.brightness,
              widget.style,
            );
            if (widget.textColors != null &&
                _samplingInputs != samplingInputs) {
              _samplingInputs = samplingInputs;
              widget.textColors!.refresh();
            }
            if (frame == null || viewport.isEmpty) {
              return ColoredBox(color: surface);
            }
            final inputs = (frame.size, viewport, _dpr!);
            if (_layoutInputs != inputs) {
              _layout = AdaptiveBackdropLayout.calculate(
                image: frame.size,
                viewport: viewport,
                devicePixelRatio: _dpr!,
                previousMode: _layout?.mode,
              );
              _layoutInputs = inputs;
            }
            if (_layout!.mode == AdaptiveBackdropMode.extended) {
              _scheduleBlur(frame);
            }
            frame.mode = _layout!.mode;
            final old = _previous;
            final oldLayout = old == null
                ? null
                : AdaptiveBackdropLayout.calculate(
                    image: old.size,
                    viewport: viewport,
                    devicePixelRatio: _dpr!,
                    previousMode: old.mode,
                  );
            if (old != null) old.mode = oldLayout!.mode;
            Widget content = AnimatedBuilder(
              animation: _transition,
              builder: (_, _) => Stack(
                fit: StackFit.expand,
                children: [
                  if (old != null) _visual(old, oldLayout!),
                  Opacity(
                    opacity: Curves.easeOutSine.transform(_transition.value),
                    child: _visual(frame, _layout!),
                  ),
                ],
              ),
            );
            if (widget.workId != null) {
              content = FilmWatchOverlay(
                store: widget.watchStore!,
                workId: widget.workId!,
                showStatus: false,
                canReveal: false,
                child: content,
              );
            }
            return Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: surface),
                content,
                ..._gradients(theme, viewport),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _sampleBoundary({required Widget child}) => widget.textColors == null
      ? child
      : FilmBackdropSamplingBoundary(
          controller: widget.textColors!,
          child: child,
        );

  Widget _visual(_BackdropFrame frame, AdaptiveBackdropLayout layout) {
    Widget sharp(BoxFit fit) => RawImage(
      key: const Key('adaptive-backdrop-sharp'),
      image: frame.info.image,
      scale: frame.info.scale,
      fit: fit,
      filterQuality: FilterQuality.high,
    );
    if (layout.mode == AdaptiveBackdropMode.cover) return sharp(BoxFit.cover);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (frame.blur case final blur?)
          Image(
            key: ValueKey(blur.path),
            image: FileImage(blur),
            gaplessPlayback: true,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            frameBuilder: (_, child, decodedFrame, _) {
              if (decodedFrame != null && !frame.blurPainted) {
                frame.blurPainted = true;
                if (_current == frame) widget.textColors?.refresh();
              }
              return child;
            },
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        Positioned.fromRect(
          rect: layout.foreground,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => RadialGradient(
              center: const Alignment(.04, -.02),
              radius: 1,
              colors: const [Colors.white, Colors.white, Colors.transparent],
              stops: const [0, .39, .65],
              // CSS farthest-corner 椭圆：单位方形上的圆再等比映射到图片边界。
              transform: _BackdropEllipse(bounds.size),
            ).createShader(bounds),
            child: sharp(BoxFit.contain),
          ),
        ),
      ],
    );
  }

  List<Widget> _gradients(ThemeData theme, Size viewport) {
    if (widget.style == FilmBackdropStyle.showcase) {
      return [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color(0x66000000),
                Colors.transparent,
                Colors.transparent,
                Color(0x66000000),
              ],
              stops: [0, .18, .82, 1],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x59000000), Colors.transparent],
              stops: [0, .28],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -.08),
              radius: .5,
              colors: [Color(0x59000000), Colors.transparent],
              stops: [.25, 1],
              transform: _ShowcaseEllipse(),
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black],
              stops: [.62, 1],
            ),
          ),
        ),
      ];
    }
    final base = theme.scaffoldBackgroundColor.withValues(alpha: 1);
    final library = widget.style == FilmBackdropStyle.library;
    final dark = theme.brightness == Brightness.dark;
    final narrow = viewport.width < 800;
    return [
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: library
                ? [
                    base.withValues(alpha: dark ? .90 : .96),
                    base.withValues(alpha: dark ? .58 : .78),
                    base.withValues(alpha: dark ? .36 : .66),
                  ]
                : [
                    base.withValues(alpha: dark && !narrow ? .84 : .96),
                    base.withValues(alpha: narrow ? .86 : .78),
                    base.withValues(alpha: narrow ? .78 : (dark ? .66 : .56)),
                    base.withValues(alpha: narrow ? .74 : (dark ? .08 : .38)),
                  ],
            stops: library
                ? const [0, .48, 1]
                : dark && !narrow
                ? const [0, .30, .72, 1]
                : const [0, .4, .72, 1],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: library
                ? [
                    base.withValues(alpha: dark ? .72 : .86),
                    base.withValues(alpha: .64),
                    base,
                  ]
                : [
                    base.withValues(alpha: dark ? .24 : .65),
                    base.withValues(alpha: .10),
                    base.withValues(alpha: .72),
                    base,
                  ],
            stops: library ? const [0, .64, 1] : const [0, .35, .72, 1],
          ),
        ),
      ),
    ];
  }
}

class _ShowcaseEllipse extends GradientTransform {
  const _ShowcaseEllipse();

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final center = const Alignment(0, -.08).withinRect(bounds);
    return Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(
        bounds.width / bounds.shortestSide,
        bounds.height * .8 / bounds.shortestSide,
        1,
        1,
      )
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }
}

class _BackdropFrame {
  _BackdropFrame(this.file, this.provider, this.info, this.thumbnailPath);
  final File file;
  final ImageProvider<Object> provider;
  final ImageInfo info;
  final String? thumbnailPath;
  File? blur;
  bool blurRequested = false;
  bool blurPainted = false;
  AdaptiveBackdropMode? mode;
  Size get size =>
      Size(info.image.width.toDouble(), info.image.height.toDouble());
}

class _BackdropEllipse extends GradientTransform {
  const _BackdropEllipse(this.size);
  final Size size;
  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final center = const Alignment(.04, -.02).withinRect(bounds);
    return Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(
        size.width * .52 * math.sqrt2 / size.shortestSide,
        size.height * .51 * math.sqrt2 / size.shortestSide,
        1,
        1,
      )
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }
}
