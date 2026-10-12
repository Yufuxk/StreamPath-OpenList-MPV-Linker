import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../domain/services/film_catalog_image_cache.dart';
import '../localization/app_localizations.dart';
import 'film_logo_layout.dart';
import 'sp_icons.dart';

/// 封面缩放独立合成，悬停不改变布局与图片解码身份。
class FilmCoverZoom extends StatefulWidget {
  const FilmCoverZoom({
    super.key,
    required this.child,
    this.hovered,
    this.scale = 1.04,
    this.duration = const Duration(milliseconds: 160),
  });
  final Widget child;
  final bool? hovered;
  final double scale;
  final Duration duration;
  @override
  State<FilmCoverZoom> createState() => _FilmCoverZoomState();
}

class _FilmCoverZoomState extends State<FilmCoverZoom>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  late final AnimationController _controller;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _scale = AlwaysStoppedAnimation(
      (widget.hovered ?? _hovered) ? widget.scale : 1,
    );
  }

  void _animate(bool hovered) {
    _scale = Tween<double>(begin: _scale.value, end: hovered ? widget.scale : 1)
        .chain(
          CurveTween(
            curve: hovered ? Curves.easeOutCubic : Curves.easeInOutCubic,
          ),
        )
        .animate(_controller);
    _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(FilmCoverZoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (widget.hovered != oldWidget.hovered ||
        widget.scale != oldWidget.scale) {
      _animate(widget.hovered ?? _hovered);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zoom = AnimatedBuilder(
      animation: _controller,
      builder: (_, child) => Transform.scale(scale: _scale.value, child: child),
      child: RepaintBoundary(child: widget.child),
    );
    return widget.hovered != null
        ? zoom
        : MouseRegion(
            onEnter: (_) => setState(() {
              _hovered = true;
              _animate(true);
            }),
            onExit: (_) => setState(() {
              _hovered = false;
              _animate(false);
            }),
            child: zoom,
          );
  }
}

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

/// 封面从首个已解码图片帧开始淡入，重建时保持当前透明度。
Widget filmCoverFrameBuilder(
  BuildContext context,
  Widget child,
  int? frame,
  bool synchronouslyLoaded,
) => TweenAnimationBuilder<double>(
  tween: Tween(begin: 0, end: frame == null ? 0 : 1),
  duration: const Duration(milliseconds: 280),
  curve: Curves.easeOut,
  child: child,
  builder: (_, opacity, image) => Opacity(opacity: opacity, child: image),
);

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
    this.transparent = false,
    this.logoGlyphSize,
    this.fallbackPath,
  }) : assert(logoGlyphSize == null || transparent);
  final FilmCatalogImageCache cache;
  final String? path;
  final String target;
  final double? width;
  final double? height;
  final double? aspectRatio;
  final double borderRadius;
  final Widget? placeholder;
  final bool transparent;

  /// 按透明内容居中并估算字形尺度，计算完成前保留空白。
  final double? logoGlyphSize;
  final String? fallbackPath;
  @override
  State<FilmArtwork> createState() => _FilmArtworkState();
}

class _FilmArtworkState extends State<FilmArtwork> {
  Future<File>? _image;
  void _load() => _image = widget.path == null
      ? null
      : widget.cache.get(widget.path!, target: widget.target);

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
        oldWidget.target != widget.target) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final known = widget.cache.knownFile(widget.path, widget.target);
    final artwork = ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: ColoredBox(
        color: widget.transparent
            ? Colors.transparent
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        child: FutureBuilder<File>(
          key: ValueKey((widget.cache, widget.path, widget.target)),
          future: _image,
          initialData: known,
          builder: (context, state) {
            final fallback = state.hasError ? null : _readyFallback();
            final file = state.data;
            if (file != null || fallback != null) {
              final provider = file != null
                  ? filmArtworkProvider(file, target: widget.target)
                  : fallback!;
              return _renderImage(
                provider,
                fallback: fallback,
                fit: widget.transparent ? BoxFit.contain : BoxFit.cover,
                alignment: widget.transparent
                    ? Alignment.centerLeft
                    : Alignment.center,
              );
            }
            if (widget.logoGlyphSize != null &&
                widget.path != null &&
                !state.hasError) {
              return const SizedBox.expand();
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
  }) {
    if (widget.logoGlyphSize != null) {
      return _ContentAlignedLogo(
        key: ValueKey((widget.cache, widget.path, widget.target)),
        cache: widget.cache,
        provider: provider,
        glyphSize: widget.logoGlyphSize!,
        placeholder: _placeholder(retry: true),
      );
    }
    return Image(
      key: widget.transparent
          ? null
          : ValueKey((widget.cache, widget.path, widget.target)),
      image: provider,
      fit: fit,
      alignment: alignment,
      filterQuality: filterQuality,
      frameBuilder: (context, child, frame, synchronouslyLoaded) {
        final image = frame != null || fallback == null
            ? child
            : Image(
                image: fallback,
                fit: fit,
                alignment: alignment,
                filterQuality: filterQuality,
              );
        if (widget.transparent) {
          return _logoOutline(context, image);
        }
        return filmCoverFrameBuilder(
          context,
          image,
          frame ?? (fallback == null ? null : 0),
          synchronouslyLoaded,
        );
      },
      errorBuilder: (_, _, _) => _placeholder(retry: true),
    );
  }

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

Widget _logoOutline(BuildContext context, Widget image) {
  if (Theme.of(context).brightness == Brightness.dark) return image;
  // 轮廓复用同一解码帧，保留原色与透明区域。
  return Stack(
    fit: StackFit.passthrough,
    children: [
      ImageFiltered(
        imageFilter: ui.ImageFilter.dilate(radiusX: 1.25, radiusY: 1.25),
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(
            Colors.black.withValues(alpha: .84),
            BlendMode.srcIn,
          ),
          child: image,
        ),
      ),
      image,
    ],
  );
}

final _logoAnalyses =
    Expando<Map<(int, ImageProvider<Object>), _LogoAnalysis>>();

class _LogoAnalysis {
  _LogoAnalysis(this.result);
  final Future<FilmLogoLayout?> result;
  FilmLogoLayout? layout;
  bool ready = false;
}

FilmLogoLayout? _measureLogo((TransferableTypedData, int, int) input) =>
    FilmLogoLayout.analyze(
      input.$1.materialize().asUint8List(),
      input.$2,
      input.$3,
    );

_LogoAnalysis _analyzeLogo(
  FilmCatalogImageCache cache,
  ImageProvider<Object> provider,
  ui.Image image,
) {
  final analyses = _logoAnalyses[cache] ??= {};
  final key = (cache.revision, provider);
  final known = analyses.remove(key);
  if (known != null) {
    analyses[key] = known;
    return known;
  }
  final copy = image.clone();
  final result = () async {
    final width = copy.width, height = copy.height;
    late TransferableTypedData pixels;
    try {
      final data = await copy.toByteData(format: ui.ImageByteFormat.rawRgba);
      pixels = TransferableTypedData.fromList([data!.buffer.asUint8List()]);
    } finally {
      copy.dispose();
    }
    return compute(_measureLogo, (pixels, width, height));
  }();
  final analysis = _LogoAnalysis(result);
  analyses[key] = analysis;
  // 与已确认文件位置缓存采用同一容量，只保存布局数值。
  if (analyses.length > 128) analyses.remove(analyses.keys.first);
  unawaited(
    result.then<void>(
      (layout) {
        analysis.layout = layout;
        analysis.ready = true;
      },
      onError: (Object _, StackTrace _) {
        if (analyses[key] == analysis) analyses.remove(key);
      },
    ),
  );
  return analysis;
}

class _ContentAlignedLogo extends StatefulWidget {
  const _ContentAlignedLogo({
    super.key,
    required this.cache,
    required this.provider,
    required this.glyphSize,
    required this.placeholder,
  });
  final FilmCatalogImageCache cache;
  final ImageProvider<Object> provider;
  final double glyphSize;
  final Widget placeholder;

  @override
  State<_ContentAlignedLogo> createState() => _ContentAlignedLogoState();
}

class _ContentAlignedLogoState extends State<_ContentAlignedLogo> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _info;
  FilmLogoLayout? _layout;
  bool _started = false, _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final stream = _stream = widget.provider.resolve(
      createLocalImageConfiguration(context),
    );
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        _stopStream();
        _info = info;
        final analysis = _analyzeLogo(
          widget.cache,
          widget.provider,
          info.image,
        );
        if (analysis.ready) {
          setState(() {
            _layout = analysis.layout;
            _failed = _layout == null;
          });
        } else {
          unawaited(_prepare(analysis));
        }
      },
      onError: (Object error, StackTrace? stack) {
        _stopStream();
        setState(() => _failed = true);
      },
    );
    _listener = listener;
    stream.addListener(listener);
  }

  Future<void> _prepare(_LogoAnalysis analysis) async {
    try {
      final layout = await analysis.result;
      if (!mounted) return;
      setState(() {
        _layout = layout;
        _failed = layout == null;
      });
    } catch (error, stack) {
      if (mounted) setState(() => _failed = true);
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'film artwork',
          context: ErrorDescription('while analyzing a film logo'),
        ),
      );
    }
  }

  void _stopStream() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _stopStream();
    _info?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.placeholder;
    if (_layout == null) return const SizedBox.expand();
    return _logoOutline(
      context,
      CustomPaint(
        painter: _LogoPainter(_info!.image, _layout!, widget.glyphSize),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.image, this.layout, this.glyphSize);
  final ui.Image image;
  final FilmLogoLayout layout;
  final double glyphSize;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawImageRect(
    image,
    layout.bounds,
    layout.destination(size, glyphSize),
    Paint()..filterQuality = FilterQuality.medium,
  );

  @override
  bool shouldRepaint(_LogoPainter oldDelegate) =>
      image != oldDelegate.image ||
      layout != oldDelegate.layout ||
      glyphSize != oldDelegate.glyphSize;
}
