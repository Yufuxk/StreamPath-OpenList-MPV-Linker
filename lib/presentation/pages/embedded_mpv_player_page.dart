import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/errors/app_exception.dart';
import '../../domain/services/mpv_window_coordinator.dart';
import '../localization/app_localizations.dart';
import '../widgets/sp_notice.dart';
import '../widgets/window_title_bar.dart';

/// 只承载原生视频区域，媒体控制继续由 MPV 及其插件提供。
class MpvPlaybackNavigation extends NavigatorObserver {
  MpvPlaybackNavigation(this.coordinator) {
    coordinator
      ..onReady = _show
      ..awaitsHostPaint = true
      ..repaintHost = _repaintHost
      ..addListener(_changed);
    _notices = coordinator.notices.listen(_notice);
  }

  final MpvWindowCoordinator coordinator;
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();

  /// 内嵌播放页是否真正挂载，宿主据此隐藏标题栏与切换沉浸布局。
  final embeddedVisible = ValueNotifier<bool>(false);
  late final StreamSubscription<String> _notices;
  Route<void>? _page;
  EmbeddedMpvLaunch? _launch;
  EmbeddedMpvLaunch? _waiting;
  Route<dynamic>? _top;

  void _notice(String source) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    messengerKey.currentState?.showSnackBar(
      SPNotice(content: Text(context.l10n.text(source))),
    );
  }

  Future<void> _show(EmbeddedMpvLaunch launch) async {
    if (identical(_launch, launch)) return;
    if (_top is PopupRoute) {
      _waiting = launch;
      return;
    }
    final navigator = navigatorKey.currentState;
    if (navigator == null || !identical(coordinator.active, launch)) return;
    _launch = launch;
    // 非不透明路由让下层页面保持布局与绘制，关闭时可直接显示已完成的界面。
    final page = PageRouteBuilder<void>(
      settings: const RouteSettings(name: '/embedded-mpv'),
      opaque: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, _, _) =>
          EmbeddedMpvPlayerPage(coordinator: coordinator, launch: launch),
    );
    _page = page;
    embeddedVisible.value = true;
    unawaited(navigator.push(page));
  }

  void _changed() {
    final page = _page;
    if (page == null || identical(coordinator.active, _launch)) return;
    _page = null;
    _launch = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (page.navigator != null) page.navigator!.removeRoute(page);
      embeddedVisible.value = false;
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _visibility(Route<dynamic>? route) {
    unawaited(
      coordinator.setVisible(route == _page).catchError((Object error) {
        debugPrint('MPV surface visibility failed: ${error.runtimeType}');
      }),
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _top = route;
    _visibility(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _top = previousRoute;
    _visibility(previousRoute);
    final waiting = _waiting;
    if (waiting != null && previousRoute is! PopupRoute) {
      _waiting = null;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_show(waiting)),
      );
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route == _page) {
      _page = null;
      _launch = null;
      embeddedVisible.value = false;
    }
    _visibility(_page?.isCurrent == true ? _page : null);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _visibility(newRoute);

  /// 强制整窗重绘两帧，覆盖原生表面销毁后失效的窗口区域。
  Future<void> _repaintHost() async {
    final binding = WidgetsBinding.instance;
    for (var frame = 0; frame < 2; frame++) {
      for (final view in binding.renderViews) {
        view.markNeedsPaint();
      }
      binding.scheduleFrame();
      await binding.endOfFrame;
    }
  }

  void dispose() {
    coordinator.onReady = null;
    coordinator.awaitsHostPaint = false;
    coordinator.repaintHost = null;
    coordinator.removeListener(_changed);
    embeddedVisible.dispose();
    unawaited(_notices.cancel());
  }
}

class EmbeddedMpvPlayerPage extends StatefulWidget {
  const EmbeddedMpvPlayerPage({
    super.key,
    required this.coordinator,
    required this.launch,
  });
  final MpvWindowCoordinator coordinator;
  final EmbeddedMpvLaunch launch;

  @override
  State<EmbeddedMpvPlayerPage> createState() => _EmbeddedMpvPlayerPageState();
}

class _EmbeddedMpvPlayerPageState extends State<EmbeddedMpvPlayerPage>
    with WidgetsBindingObserver {
  final _surface = GlobalKey();
  Rect? _lastBounds;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    _lastBounds = null;
    _layout();
  }

  void _layout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(widget.coordinator.active, widget.launch)) {
        return;
      }
      final box = _surface.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final bounds = box.localToGlobal(Offset.zero) & box.size;
      if (_lastBounds == bounds) return;
      _lastBounds = bounds;
      final ratio = View.of(context).devicePixelRatio;
      unawaited(
        widget.coordinator.setBounds(
          widget.launch.host,
          (bounds.left * ratio).round(),
          (bounds.top * ratio).round(),
          (bounds.width * ratio).round(),
          (bounds.height * ratio).round(),
        ),
      );
    });
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy || !identical(widget.coordinator.active, widget.launch)) return;
    setState(() => _busy = true);
    try {
      await action();
    } on AppException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SPNotice(content: Text(context.l10n.text(error.message))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_action(widget.coordinator.detach));
    },
    child: ListenableBuilder(
      listenable: widget.coordinator,
      builder: (context, _) {
        _layout();
        return Scaffold(
          backgroundColor: Colors.black,
          body: Column(
            children: [
              // 窗口模式下让出标题栏高度，宿主窗口才能响应拖动与缩放。
              if (!widget.coordinator.fullscreen)
                const SizedBox(height: WindowTitleBar.height),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _layout();
                    return SizedBox.expand(key: _surface);
                  },
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
