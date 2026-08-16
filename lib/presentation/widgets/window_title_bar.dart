import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 无系统标题栏时的自绘窗口标题栏。
///
/// 接管原 Windows 标题栏的职责：显示应用标识并提供最小化 / 最大化（还原）/
/// 关闭按钮。拖动与双击最大化由原生标题栏命中测试处理，其余窗口控制通过
/// `streampath/appearance` 通道转发给原生 runner。
///
/// 背景使用页面 AppBar 与 Scaffold 的等价合成色，因此磨砂模式下两者
/// 具有相同的透明度与最终观感。
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key});

  /// 标题栏高度，与 Windows 11 系统标题栏高度一致。
  static const double height = 32;

  @visibleForTesting
  static const minimizeButtonKey = Key('window-minimize-button');

  @visibleForTesting
  static const maximizeButtonKey = Key('window-maximize-button');

  @visibleForTesting
  static const closeButtonKey = Key('window-close-button');

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

  /// 当前是否最大化（决定“最大化/还原”图标）。
  bool _maximized = false;

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
    _channel.setMethodCallHandler(_handleNativeCall);
    _syncMaximizedState();
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 原生窗口大小变化时同步最大化状态。
  Future<void> _handleNativeCall(MethodCall call) async {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final backgroundColor = _titleBarColor(theme);
    // 页面 AppBar、自绘标题栏与原生圆角填充只使用这一处顶栏色源。
    _syncFrameColor(backgroundColor);
    return Material(
      color: backgroundColor,
      child: SizedBox(
        height: WindowTitleBar.height,
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  const SizedBox(width: 20),
                  _TitleBarMark(color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'StreamPath',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.1,
                    ),
                  ),
                ],
              ),
            ),
            _WindowButton(
              key: WindowTitleBar.minimizeButtonKey,
              icon: _WindowControlIconType.minimize,
              iconKey: WindowTitleBar.minimizeIconKey,
              tooltip: '最小化',
              onPressed: () => _invoke('minimize'),
            ),
            _WindowButton(
              key: WindowTitleBar.maximizeButtonKey,
              icon: _maximized
                  ? _WindowControlIconType.restore
                  : _WindowControlIconType.maximize,
              iconKey: WindowTitleBar.maximizeIconKey,
              tooltip: _maximized ? '还原' : '最大化',
              onPressed: _toggleMaximize,
            ),
            _WindowButton(
              key: WindowTitleBar.closeButtonKey,
              icon: _WindowControlIconType.close,
              iconKey: WindowTitleBar.closeIconKey,
              tooltip: '关闭',
              onPressed: () => _invoke('close'),
              close: true,
            ),
          ],
        ),
      ),
    );
  }

  Color _titleBarColor(ThemeData theme) => Color.alphaBlend(
    theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface,
    theme.scaffoldBackgroundColor,
  );
}

/// 复用应用图标的“文件夹 + 播放”构图，适配标题栏小尺寸显示。
class _TitleBarMark extends StatelessWidget {
  const _TitleBarMark({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        width: 16,
        height: 16,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(Icons.folder_outlined, size: 16, color: color),
            Icon(Icons.play_arrow_rounded, size: 10, color: color),
          ],
        ),
      ),
    );
  }
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

enum _WindowControlIconType { minimize, maximize, restore, close }

/// 使用 Windows 系统 Caption 字形，保持原生线条比例与 DPI 渲染。
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
          child: Text(
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
  };
}
