import 'dart:async';

import 'package:flutter/material.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../theme/appearance_controller.dart';
import 'sp_notice.dart';

/// 无系统标题栏时的自绘窗口标题栏。
///
/// 提供全屏、最小化、最大化（还原）和关闭按钮。
/// 拖动与双击最大化由原生标题栏命中测试处理，其余窗口控制通过
/// `streampath/appearance` 通道转发给原生 runner。
///
/// 普通页面匹配 AppBar，影视页面保持透明。
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key, this.detailScrollProgress});

  final double? detailScrollProgress;

  /// 标题栏高度，与 Windows 11 系统标题栏高度一致。
  static const double height = 32;
  static const double compactSidebarWidth = 64;
  static const sidebarSlideDuration = Duration(milliseconds: 180);

  @visibleForTesting
  static const sidebarSurfaceKey = Key('window-titlebar-sidebar-surface');

  @visibleForTesting
  static const sidebarEdgeKey = Key('window-titlebar-sidebar-edge');

  @visibleForTesting
  static const mainSurfaceKey = Key('window-titlebar-main-surface');

  @visibleForTesting
  static const minimizeButtonKey = Key('window-minimize-button');

  @visibleForTesting
  static const maximizeButtonKey = Key('window-maximize-button');

  @visibleForTesting
  static const closeButtonKey = Key('window-close-button');
  static const fullscreenButtonKey = Key('window-fullscreen-button');
  static const fullscreenIconKey = Key('window-fullscreen-icon');

  @visibleForTesting
  static const minimizeIconKey = Key('window-minimize-icon');

  @visibleForTesting
  static const maximizeIconKey = Key('window-maximize-icon');

  @visibleForTesting
  static const closeIconKey = Key('window-close-icon');

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar>
    with WidgetsBindingObserver {
  static const MethodChannel _channel = MethodChannel('streampath/appearance');
  static _WindowTitleBarState? _nativeHandlerOwner;

  /// 当前是否最大化（决定“最大化/还原”图标）。
  bool _maximized = false;
  bool _fullscreen = false;

  /// 最近一次已推送给原生的窗口框架色。
  int? _lastFrameColor;

  /// 让原生窗口框架（圆角填充与边框条）使用与自绘标题栏完全相同的颜色，
  /// 避免两段区域出现色差。
  void _syncFrameColor(Color topBarColor) {
    final argb = topBarColor.toARGB32();
    if (_lastFrameColor == argb) return;
    _lastFrameColor = argb;
    unawaited(_pushFrameColor(argb));
  }

  Future<void> _pushFrameColor(int argb) async {
    try {
      await _channel.invokeMethod<void>('setFrameColor', <String, dynamic>{
        'r': (argb >> 16) & 0xFF,
        'g': (argb >> 8) & 0xFF,
        'b': argb & 0xFF,
        // 半透明时原生框架保持透明，由 Flutter 直接绘制圆角区域。
        'a': (argb >> 24) & 0xFF,
      });
    } on PlatformException {
      // 原生通道不可用时忽略，仅影响窗口框架颜色。
    } on MissingPluginException {
      // 同上。
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nativeHandlerOwner = this;
    _channel.setMethodCallHandler(_handleNativeCall);
    _syncMaximizedState();
    _syncFullscreenState();
    HardwareKeyboard.instance.addHandler(_handleFullscreenKey);
  }

  @override
  void didChangePlatformBrightness() {
    // 明暗切换会触发原生磨砂层重置窗口框架色，且与主题重建没有固定先后，
    // 延迟一段时间后按重建后的主题重新推送，保证框架色与标题栏始终一致。
    unawaited(_rePushFrameColorDelayed());
  }

  Future<void> _rePushFrameColorDelayed() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    _lastFrameColor = null;
    _syncFrameColor(_titleBarColor(Theme.of(context)));
  }

  @override
  void dispose() {
    if (identical(_nativeHandlerOwner, this)) {
      _channel.setMethodCallHandler(null);
      _nativeHandlerOwner = null;
    }
    HardwareKeyboard.instance.removeHandler(_handleFullscreenKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 原生窗口大小变化时同步最大化状态。
  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'fullscreenChanged') {
      if (mounted) setState(() => _fullscreen = call.arguments == true);
      return;
    }
    if (call.method == 'accentChanged') {
      await context.read<AppearanceController>().refreshSystemAccent();
      return;
    }
    if (call.method != 'maximizeChanged') return;
    final maximized = call.arguments == true;
    if (mounted && maximized != _maximized) {
      setState(() => _maximized = maximized);
    }
  }

  Future<void> _syncMaximizedState() async {
    try {
      final maximized = await _channel.invokeMethod<bool>('isMaximized');
      if (mounted && maximized != null && maximized != _maximized) {
        setState(() => _maximized = maximized);
      }
    } on PlatformException {
      // 测试环境或非 Windows 构建没有原生实现，保持默认状态。
    } on MissingPluginException {
      // 同上。
    }
  }

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException {
      // 原生通道不可用时忽略，仅影响窗口操作。
    } on MissingPluginException {
      // 同上。
    }
  }

  Future<void> _toggleMaximize() async {
    if (_fullscreen) return _toggleFullscreen();
    try {
      final maximized = await _channel.invokeMethod<bool>('toggleMaximize');
      if (mounted && maximized != null && maximized != _maximized) {
        setState(() => _maximized = maximized);
      }
    } on PlatformException {
      // 原生通道不可用时忽略。
    } on MissingPluginException {
      // 同上。
    }
  }

  bool _handleFullscreenKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.f11 ||
        (_fullscreen && event.logicalKey == LogicalKeyboardKey.escape)) {
      unawaited(_toggleFullscreen());
      return true;
    }
    return false;
  }

  Future<void> _syncFullscreenState() async {
    try {
      final fullscreen = await _channel.invokeMethod<bool>('isFullscreen');
      if (mounted && fullscreen != null) {
        setState(() => _fullscreen = fullscreen);
      }
    } on MissingPluginException {
      // 非 Windows 和组件测试不提供窗口通道。
    }
  }

  Future<void> _toggleFullscreen() async {
    try {
      final fullscreen = await _channel.invokeMethod<bool>('toggleFullscreen');
      if (mounted && fullscreen != null) {
        setState(() => _fullscreen = fullscreen);
      }
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SPNotice(content: AppText('无法切换全屏')));
      }
    } on MissingPluginException {
      // 非 Windows 和组件测试不提供窗口通道。
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final backgroundColor = _titleBarColor(theme);
    // 主内容区与原生圆角填充沿用 AppBar 的合成色。
    _syncFrameColor(backgroundColor);
    return _buildChrome(backgroundColor);
  }

  Widget _buildChrome(Color backgroundColor) {
    final immersive = widget.detailScrollProgress != null;
    final chrome = SizedBox(
      height: WindowTitleBar.height,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: 0,
            child: Material(
              key: WindowTitleBar.mainSurfaceKey,
              color: immersive ? Colors.transparent : backgroundColor,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _WindowButton(
                    key: WindowTitleBar.fullscreenButtonKey,
                    icon: _fullscreen
                        ? _WindowControlIconType.exitFullscreen
                        : _WindowControlIconType.fullscreen,
                    iconKey: WindowTitleBar.fullscreenIconKey,
                    tooltip: context.l10n.text(_fullscreen ? '退出全屏' : '全屏'),
                    onPressed: _toggleFullscreen,
                  ),
                  _WindowButton(
                    key: WindowTitleBar.minimizeButtonKey,
                    icon: _WindowControlIconType.minimize,
                    iconKey: WindowTitleBar.minimizeIconKey,
                    tooltip: context.l10n.text('最小化'),
                    onPressed: () => _invoke('minimize'),
                  ),
                  _WindowButton(
                    key: WindowTitleBar.maximizeButtonKey,
                    icon: _maximized || _fullscreen
                        ? _WindowControlIconType.restore
                        : _WindowControlIconType.maximize,
                    iconKey: WindowTitleBar.maximizeIconKey,
                    tooltip: context.l10n.text(
                      _fullscreen
                          ? '退出全屏'
                          : _maximized
                          ? '还原'
                          : '最大化',
                    ),
                    onPressed: _toggleMaximize,
                  ),
                  _WindowButton(
                    key: WindowTitleBar.closeButtonKey,
                    icon: _WindowControlIconType.close,
                    iconKey: WindowTitleBar.closeIconKey,
                    tooltip: context.l10n.text('关闭'),
                    onPressed: () => _invoke('close'),
                    close: true,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return chrome;
  }

  Color _titleBarColor(ThemeData theme) => Color.alphaBlend(
    theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface,
    theme.scaffoldBackgroundColor,
  );
}

/// 标题栏右侧的最小化 / 最大化（还原）/ 关闭按钮，尺寸与系统标题栏按钮一致。
class _WindowButton extends StatefulWidget {
  const _WindowButton({
    super.key,
    required this.icon,
    required this.iconKey,
    required this.tooltip,
    required this.onPressed,
    this.close = false,
  });

  final _WindowControlIconType icon;
  final Key iconKey;
  final String tooltip;
  final VoidCallback onPressed;

  /// 关闭按钮使用与 Windows 一致的危险色悬停反馈。
  final bool close;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hoverColor = widget.close
        ? const Color(0xFFC42B1C)
        : scheme.onSurface.withValues(alpha: 0.08);
    return Tooltip(
      message: widget.tooltip,
      child: InkWell(
        onTap: widget.onPressed,
        onHover: (hovered) => setState(() => _hovered = hovered),
        hoverColor: hoverColor,
        splashColor: Colors.transparent,
        highlightColor: hoverColor,
        child: SizedBox(
          width: 46,
          height: WindowTitleBar.height,
          child: Center(
            child: _WindowsCaptionGlyph(
              key: widget.iconKey,
              type: widget.icon,
              color: widget.close && _hovered
                  ? Colors.white
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

enum _WindowControlIconType {
  minimize,
  maximize,
  restore,
  close,
  fullscreen,
  exitFullscreen,
}

/// 窗口控制使用系统 Caption 字形，全屏使用同色的四角矢量线条。
class _WindowsCaptionGlyph extends StatelessWidget {
  const _WindowsCaptionGlyph({
    super.key,
    required this.type,
    required this.color,
  });

  static const double _size = 12;
  static const double _fontSize = 10;

  final _WindowControlIconType type;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: _size,
        child: Center(
          child:
              type == _WindowControlIconType.fullscreen ||
                  type == _WindowControlIconType.exitFullscreen
              ? CustomPaint(
                  size: const Size.square(_size),
                  painter: _FullscreenPainter(
                    color: color,
                    exit: type == _WindowControlIconType.exitFullscreen,
                  ),
                )
              : AppText(
                  _glyph,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    inherit: false,
                    color: color,
                    fontFamily: 'Segoe Fluent Icons',
                    fontFamilyFallback: const ['Segoe MDL2 Assets'],
                    fontSize: _fontSize,
                    height: 1,
                  ),
                ),
        ),
      ),
    );
  }

  String get _glyph => switch (type) {
    _WindowControlIconType.minimize => '\uE921',
    _WindowControlIconType.maximize => '\uE922',
    _WindowControlIconType.restore => '\uE923',
    _WindowControlIconType.close => '\uE8BB',
    _WindowControlIconType.fullscreen => '\uE740',
    _WindowControlIconType.exitFullscreen => '\uE73F',
  };
}

class _FullscreenPainter extends CustomPainter {
  const _FullscreenPainter({required this.color, required this.exit});
  final Color color;
  final bool exit;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (exit) {
      path
        ..moveTo(1.5, 4.5)
        ..lineTo(4.5, 4.5)
        ..lineTo(4.5, 1.5)
        ..moveTo(7.5, 1.5)
        ..lineTo(7.5, 4.5)
        ..lineTo(10.5, 4.5)
        ..moveTo(1.5, 7.5)
        ..lineTo(4.5, 7.5)
        ..lineTo(4.5, 10.5)
        ..moveTo(7.5, 10.5)
        ..lineTo(7.5, 7.5)
        ..lineTo(10.5, 7.5);
    } else {
      path
        ..moveTo(4.5, 1.5)
        ..lineTo(1.5, 1.5)
        ..lineTo(1.5, 4.5)
        ..moveTo(7.5, 1.5)
        ..lineTo(10.5, 1.5)
        ..lineTo(10.5, 4.5)
        ..moveTo(1.5, 7.5)
        ..lineTo(1.5, 10.5)
        ..lineTo(4.5, 10.5)
        ..moveTo(7.5, 10.5)
        ..lineTo(10.5, 10.5)
        ..lineTo(10.5, 7.5);
    }
    canvas.drawPath(
      path,
      Paint()
        ..isAntiAlias = true
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeJoin = StrokeJoin.miter
        ..strokeCap = StrokeCap.square,
    );
  }

  @override
  bool shouldRepaint(_FullscreenPainter oldDelegate) =>
      color != oldDelegate.color || exit != oldDelegate.exit;
}
