import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../domain/services/film_catalog_image_cache.dart';
import '../localization/app_localizations.dart';
import '../theme/app_theme.dart';
import 'film_logo_layout.dart';
import 'film_play_icon.dart';
import 'sp_icons.dart';
import 'sp_menu.dart';
import 'cinematic_states.dart';
import 'skeleton_scope.dart';

/// 固定卡片命中区域；仅 FilmPosterHoverSurface 内的海报参与动效。
class FilmPosterHover extends StatefulWidget {
  const FilmPosterHover({
    super.key,
    required this.child,
    this.hovered,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });
  final Widget child;
  final bool? hovered;
  final BorderRadius borderRadius;
  @override
  State<FilmPosterHover> createState() => _FilmPosterHoverState();
}

class _FilmPosterHoverState extends State<FilmPosterHover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _hovered = false;
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppTheme.hoverDuration,
      value: widget.hovered == true ? 1 : 0,
    );
    spMenuAnchor.addListener(_menuChanged);
  }

  void _menuChanged() {
    final anchor = spMenuAnchor.value;
    final hovered = widget.hovered ?? _hovered;
    if (!hovered && !_menuOpen) return;
    var menuOpen = false;
    if (anchor != null && hovered) {
      final box = context.findRenderObject()! as RenderBox;
      menuOpen = (Offset.zero & box.size).contains(box.globalToLocal(anchor));
    }
    if (_menuOpen == menuOpen) return;
    _menuOpen = menuOpen;
    if (!menuOpen) _animate(widget.hovered ?? _hovered);
  }

  void _animate(bool hovered) {
    if (_menuOpen) return;
    _controller.animateTo(
      hovered ? 1 : 0,
      duration: AppTheme.hoverDuration,
      curve: hovered ? Curves.easeOutCubic : Curves.easeInOutCubic,
    );
  }

  @override
  void didUpdateWidget(FilmPosterHover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hovered != oldWidget.hovered) {
      _animate(widget.hovered ?? false);
    }
  }

  @override
  void dispose() {
    spMenuAnchor.removeListener(_menuChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = _FilmPosterHoverScope(
      animation: _controller,
      borderRadius: widget.borderRadius,
      child: widget.child,
    );
    return widget.hovered != null
        ? content
        : MouseRegion(
            onEnter: (_) {
              _hovered = true;
              _animate(true);
            },
            onExit: (_) {
              _hovered = false;
              _animate(false);
            },
            child: content,
          );
  }
}

class _FilmPosterHoverScope extends InheritedWidget {
  const _FilmPosterHoverScope({
    required this.animation,
    required this.borderRadius,
    required super.child,
  });
  final Animation<double> animation;
  final BorderRadius borderRadius;

  @override
  bool updateShouldNotify(_FilmPosterHoverScope oldWidget) =>
      animation != oldWidget.animation ||
      borderRadius != oldWidget.borderRadius;
}

/// 海报单独变换，布局尺寸和外部文字始终保持原位。
class FilmPosterHoverSurface extends StatelessWidget {
  const FilmPosterHoverSurface({
    super.key,
    required this.child,
    this.borderRadius,
    this.blurred = false,
    this.showBorder = true,
    this.clipBehavior = Clip.antiAlias,
  });
  final Widget child;
  final BorderRadius? borderRadius;

  /// 已模糊内容沿用固定坐标的位图采样。
  final bool blurred;
  final bool showBorder;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_FilmPosterHoverScope>()!;
    final theme = Theme.of(context);
    final borderColor = theme.brightness == Brightness.dark
        ? Colors.white
        : theme.colorScheme.onSurface;
    final clipped = ClipRRect(
      clipBehavior: clipBehavior,
      borderRadius: borderRadius ?? scope.borderRadius,
      child: child,
    );
    return AnimatedBuilder(
      animation: scope.animation,
      builder: (_, content) {
        final progress = scope.animation.value;
        final scale = 1 + (AppTheme.posterHoverScale - 1) * progress;
        return Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.diagonal3Values(scale, scale, 1)
                    ..setEntry(1, 3, -AppTheme.posterHoverLift * progress),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: borderRadius ?? scope.borderRadius,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .45 * progress),
                          blurRadius: 24 * progress,
                          offset: Offset(0, 12 * progress),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Transform(
              alignment: Alignment.center,
              transform: Matrix4.diagonal3Values(scale, scale, 1)
                ..setEntry(1, 3, -AppTheme.posterHoverLift * progress),
              // 清晰封面直接绘制原图，模糊封面保持滤镜采样坐标稳定。
              filterQuality: blurred ? FilterQuality.high : null,
              // 动效超出占位的部分不扩大鼠标命中区。
              transformHitTests: false,
              child: Stack(
                fit: StackFit.passthrough,
                children: [
                  content!,
                  if (showBorder)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: borderRadius ?? scope.borderRadius,
                            border: Border.all(
                              color: borderColor.withValues(alpha: 0.10),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
      child: blurred ? RepaintBoundary(child: clipped) : clipped,
    );
  }
}

/// 装饰层复用封面悬停进度淡入淡出，点击始终穿透到原封面。
class FilmPosterHoverPlayIcon extends StatelessWidget {
  const FilmPosterHoverPlayIcon({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: FilmPlayIcon(
      opacity: context
          .dependOnInheritedWidgetOfExactType<_FilmPosterHoverScope>()!
          .animation,
    ),
  );
}

/// 角标跟随封面位移，抵消父级缩放以保持字号与尺寸。
class FilmPosterHoverAttachment extends StatelessWidget {
  const FilmPosterHoverAttachment({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_FilmPosterHoverScope>()!;
    return AnimatedBuilder(
      animation: scope.animation,
      child: child,
      builder: (context, child) => Transform.scale(
        scale:
            1 / (1 + (AppTheme.posterHoverScale - 1) * scope.animation.value),
        alignment: AlignmentDirectional.topStart.resolve(
          Directionality.of(context),
        ),
        child: child,
      ),
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
  // 全显后撤掉透明图层，避免悬停变换仍进入整数像素对齐路径。
  builder: (_, opacity, image) =>
      opacity == 1 ? image! : Opacity(opacity: opacity, child: image),
);

/// 海报墙同步命中直接显示，异步首帧沿用封面淡入。
Widget filmPosterFrameBuilder(
  BuildContext context,
  Widget child,
  int? frame,
  bool synchronouslyLoaded,
) => synchronouslyLoaded
    ? child
    : filmCoverFrameBuilder(context, child, frame, synchronouslyLoaded);

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
    this.logoAutoCenter = false,
    this.logoInkOutline = false,
    this.logoPadding = 0,
    this.fallbackPath,
    this.showCachedImmediately = false,
    this.provider,
  }) : assert(logoGlyphSize == null || transparent),
       assert(!logoAutoCenter || transparent),
       assert(!logoInkOutline || transparent),
       assert(logoPadding >= 0);
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

  /// 无字形目标时仍按透明内容自动居中；与 [logoGlyphSize] 独立。
  final bool logoAutoCenter;

  /// 对深色主题下近乎纯黑且没有自带亮边的徽标补对比描边；默认关闭。
  final bool logoInkOutline;

  /// 透明徽标在裁剪框内留出的空白，避免贴边字形和描边被裁掉。
  final double logoPadding;
  final String? fallbackPath;

  /// 作品与合集海报同步命中时跳过渐显，其他图片保留原策略。
  final bool showCachedImmediately;

  /// 共享元素在运动期间复用源封面，静止后恢复原目标尺寸。
  final ImageProvider<Object>? provider;
  @override
  State<FilmArtwork> createState() => _FilmArtworkState();
}

class _FilmArtworkState extends State<FilmArtwork> {
  Future<File>? _image;
  void _load() => _image = widget.path == null || widget.provider != null
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
        oldWidget.target != widget.target ||
        oldWidget.provider != widget.provider) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final known = widget.cache.knownFile(widget.path, widget.target);
    final content = widget.provider != null
        ? _renderImage(widget.provider!, fit: BoxFit.cover)
        : FutureBuilder<File>(
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
              if ((widget.logoGlyphSize != null || widget.logoAutoCenter) &&
                  widget.path != null &&
                  !state.hasError) {
                return const SkeletonLoadBoundary(
                  ready: false,
                  child: SizedBox.expand(),
                );
              }
              if (!widget.transparent &&
                  widget.path != null &&
                  !state.hasError) {
                return const SkeletonLoadBoundary(
                  ready: false,
                  child: CinematicSkeleton(showLines: false),
                );
              }
              return SkeletonLoadBoundary(
                ready: widget.path == null || state.hasError,
                child: _placeholder(retry: state.hasError),
              );
            },
          );
    final artwork = ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      clipBehavior: widget.borderRadius == 0 ? Clip.hardEdge : Clip.antiAlias,
      child: ColoredBox(
        color: widget.transparent
            ? Colors.transparent
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        child: widget.logoPadding > 0
            ? Padding(
                padding: EdgeInsets.all(widget.logoPadding),
                child: content,
              )
            : content,
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
    if (widget.logoGlyphSize != null || widget.logoAutoCenter) {
      return _ContentAlignedLogo(
        key: ValueKey((widget.cache, widget.path, widget.target)),
        cache: widget.cache,
        provider: provider,
        glyphSize: widget.logoGlyphSize,
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
        if (!widget.transparent && frame == null && fallback == null) {
          return const SkeletonLoadBoundary(
            ready: false,
            child: CinematicSkeleton(showLines: false),
          );
        }
        final image = frame != null || fallback == null
            ? child
            : Image(
                image: fallback,
                fit: fit,
                alignment: alignment,
                filterQuality: filterQuality,
              );
        if (widget.transparent) {
          return SkeletonLoadBoundary(
            ready: frame != null,
            child: widget.logoInkOutline
                ? _InkAwareLogoOutline(
                    key: ValueKey((widget.cache, widget.path, widget.target)),
                    cache: widget.cache,
                    provider: provider,
                    image: image,
                  )
                : _logoOutline(context, image),
          );
        }
        if (widget.showCachedImmediately && fallback != null) return image;
        return SkeletonLoadBoundary(
          ready: frame != null || fallback != null,
          child:
              (widget.showCachedImmediately
              ? filmPosterFrameBuilder
              : filmCoverFrameBuilder)(
                context,
                image,
                frame ?? (fallback == null ? null : 0),
                synchronouslyLoaded,
              ),
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

Widget _logoOutline(
  BuildContext context,
  Widget image, {
  Color? color,
  double radius = 1.25,
}) {
  final outline =
      color ??
      (Theme.of(context).brightness == Brightness.dark
          ? null
          : Colors.black.withValues(alpha: .84));
  if (outline == null) return image;
  // 轮廓复用同一解码帧，保留原色与透明区域。
  return Stack(
    fit: StackFit.passthrough,
    children: [
      ImageFiltered(
        imageFilter: ui.ImageFilter.dilate(radiusX: radius, radiusY: radius),
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(outline, BlendMode.srcIn),
          child: image,
        ),
      ),
      image,
    ],
  );
}

/// 详情页按徽标墨色选择对比描边：暗墨配白描边，亮墨配黑描边。
class _InkAwareLogoOutline extends StatefulWidget {
  const _InkAwareLogoOutline({
    super.key,
    required this.cache,
    required this.provider,
    required this.image,
  });
  final FilmCatalogImageCache cache;
  final ImageProvider<Object> provider;
  final Widget image;

  @override
  State<_InkAwareLogoOutline> createState() => _InkAwareLogoOutlineState();
}

class _InkAwareLogoOutlineState extends State<_InkAwareLogoOutline> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _started = false, _needsRim = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final stream = _stream = widget.provider.resolve(
      createLocalImageConfiguration(context),
    );
    late ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      _stopStream();
      final analysis = _analyzeLogo(widget.cache, widget.provider, info.image);
      info.dispose();
      if (analysis.ready) {
        _apply(analysis.layout);
      } else {
        unawaited(_prepare(analysis));
      }
    }, onError: (Object _, StackTrace? _) => _stopStream());
    _listener = listener;
    stream.addListener(listener);
  }

  void _apply(FilmLogoLayout? layout) {
    if (!mounted) return;
    setState(
      () => _needsRim =
          layout != null && layout.nearBlack && !layout.hasBrightEdge,
    );
  }

  Future<void> _prepare(_LogoAnalysis analysis) async {
    try {
      _apply(await analysis.result);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'film artwork',
          context: ErrorDescription('while measuring a detail logo ink'),
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 只给深色背景上近乎纯黑、且没有自带亮边的徽标补白色描边。
    if (!_needsRim || Theme.of(context).brightness != Brightness.dark) {
      return _logoOutline(context, widget.image);
    }
    return _logoOutline(
      context,
      widget.image,
      color: Colors.white.withValues(alpha: .9),
      radius: 2,
    );
  }
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
  final double? glyphSize;
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
  final double? glyphSize;

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
