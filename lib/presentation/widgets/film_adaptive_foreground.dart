import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'transition_content.dart';

/// 只采样背景层的小图，信息区共用一个黑白目标色。
class FilmBackdropTextController extends ChangeNotifier {
  final backgroundKey = GlobalKey();
  ByteData? _pixels;
  Size? _viewport;
  int _width = 0, _height = 0, _revision = 0;
  bool _scheduled = false, _busy = false, _disposed = false, _requested = false;

  void refresh() {
    if (_disposed) return;
    _revision++;
    _requested = true;
    _scheduleCapture();
  }

  void _painted() {
    if (_requested) _scheduleCapture();
  }

  void _scheduleCapture() {
    if (_scheduled || _busy) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) unawaited(_capture());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _capture() async {
    final context = backgroundKey.currentContext;
    if (context == null || StreamPathTransitionScope.read(context)) return;
    final boundary =
        backgroundKey.currentContext?.findRenderObject() as _SampleBoundary?;
    if (boundary == null || !boundary.ready || boundary.size.isEmpty) {
      return;
    }
    final revision = _revision;
    final size = boundary.size;
    _busy = true;
    try {
      final image = await boundary.toImage(
        pixelRatio: math.min(1, 256 / math.max(size.width, size.height)),
      );
      try {
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (_disposed ||
            revision != _revision ||
            !context.mounted ||
            StreamPathTransitionScope.read(context)) {
          return;
        }
        _pixels = pixels!;
        _viewport = size;
        _width = image.width;
        _height = image.height;
        _requested = false;
        notifyListeners();
      } finally {
        image.dispose();
      }
    } finally {
      _busy = false;
      if (!_disposed && revision != _revision) _scheduleCapture();
    }
  }

  Color choose(List<GlobalKey> textKeys, Color current) {
    final pixels = _pixels;
    final boundary =
        backgroundKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (pixels == null || boundary == null) return current;
    var blackReadable = 0, whiteReadable = 0;
    var count = 0;
    for (final key in textKeys) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      // 按实际文字行取样，居中留白和空行不参与判定。
      final textRects = box is RenderParagraph
          ? box
                .getBoxesForSelection(
                  TextSelection(
                    baseOffset: 0,
                    extentOffset: box.text.toPlainText().length,
                  ),
                )
                .map((line) => line.toRect())
          : [Offset.zero & box.size];
      for (final textRect in textRects) {
        if (textRect.isEmpty) continue;
        final rect = Rect.fromPoints(
          boundary.globalToLocal(box.localToGlobal(textRect.topLeft)),
          boundary.globalToLocal(box.localToGlobal(textRect.bottomRight)),
        ).intersect(Offset.zero & _viewport!);
        final left = (rect.left / _viewport!.width * _width).floor();
        final right = (rect.right / _viewport!.width * _width).ceil();
        final top = (rect.top / _viewport!.height * _height).floor();
        final bottom = (rect.bottom / _viewport!.height * _height).ceil();
        for (var y = top; y < bottom; y++) {
          for (var x = left; x < right; x++) {
            final offset = (y * _width + x) * 4;
            final luminance = Color.fromARGB(
              255,
              pixels.getUint8(offset),
              pixels.getUint8(offset + 1),
              pixels.getUint8(offset + 2),
            ).computeLuminance();
            // 比较可读区域占比，避免少量亮斑抵消暗部的低对比度。
            if ((luminance + .05) / .05 >= 4.5) blackReadable++;
            if (1.05 / (luminance + .05) >= 4.5) whiteReadable++;
            count++;
          }
        }
      }
    }
    if (count == 0) return current;
    final difference = (blackReadable - whiteReadable) / count;
    // 可读占比接近时保留当前选择，避免缩放或滚动时来回切换。
    if (difference > .02) return Colors.black;
    if (difference < -.02) return Colors.white;
    return current;
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _pixels = null;
    super.dispose();
  }
}

class FilmBackdropSamplingBoundary extends SingleChildRenderObjectWidget {
  FilmBackdropSamplingBoundary({
    required this.controller,
    required Widget child,
  }) : super(key: controller.backgroundKey, child: child);
  final FilmBackdropTextController controller;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _SampleBoundary(controller._painted);
}

class _SampleBoundary extends RenderRepaintBoundary {
  _SampleBoundary(this.onPaint);
  final VoidCallback onPaint;
  bool ready = false;

  @override
  void markNeedsPaint() {
    ready = false;
    super.markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    ready = true;
    onPaint();
  }
}

class FilmAdaptiveForeground extends StatefulWidget {
  const FilmAdaptiveForeground({
    super.key,
    required this.controller,
    required this.textKeys,
    required this.scrollController,
    required this.builder,
  });
  final FilmBackdropTextController controller;
  final List<GlobalKey> textKeys;
  final ScrollController scrollController;
  final Widget Function(BuildContext, Color) builder;

  @override
  State<FilmAdaptiveForeground> createState() => _FilmAdaptiveForegroundState();
}

class _FilmAdaptiveForegroundState extends State<FilmAdaptiveForeground> {
  Color? _target;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_schedule);
    widget.scrollController.addListener(_schedule);
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || StreamPathTransitionScope.read(context)) return;
      final next = widget.controller.choose(widget.textKeys, _target!);
      if (next != _target) setState(() => _target = next);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_schedule);
    widget.scrollController.removeListener(_schedule);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _target ??= Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    _schedule();
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: _target, end: _target),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutSine,
      builder: (context, color, _) => widget.builder(context, color!),
    );
  }
}
