import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/appearance_config.dart';
import '../../data/models/media_library_item.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/glass_tokens.dart';
import '../widgets/sp_icons.dart';
import '../widgets/sp_notice.dart';
import '../widgets/window_title_bar.dart';
import 'browser_page.dart';
import 'global_media_library_page.dart';
import 'global_search_page.dart';
import 'local_storage_page.dart';
import 'mount_management_page.dart';
import 'network_storage_page.dart';
import 'settings_page.dart';

enum _Section { network, local, library, mounts, search, settings }

/// 浏览分支保持挂载，使切换侧边栏不会停止播放监控。
class AppShellPage extends StatefulWidget {
  const AppShellPage({super.key, this.initialError});
  final String? initialError;

  @override
  State<AppShellPage> createState() => _AppShellPageState();
}

class _AppShellPageState extends State<AppShellPage>
    with SingleTickerProviderStateMixin {
  static const _width = WindowTitleBar.sidebarWidth;
  static const _triggerWidth = WindowTitleBar.sidebarTriggerWidth;
  static const _hoverWidth = 36.0;
  static const _slideDuration = WindowTitleBar.sidebarSlideDuration;
  final _keys = {
    for (final section in _Section.values) section: GlobalKey<NavigatorState>(),
  };
  final Set<_Section> _built = {};
  final Set<_Section> _restored = {};
  late _Section _selected;
  bool _expanded = false;
  bool _hoveringTrigger = false;
  bool _hoveringSidebar = false;
  Timer? _hideTimer;
  late final AnimationController _slideController;
  late final CurvedAnimation _slideProgress;
  late final ValueNotifier<double> _sharedProgress;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _sharedProgress = app.sidebarRevealProgress;
    _slideController = AnimationController(
      vsync: this,
      duration: _slideDuration,
    );
    _slideProgress = CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    )..addListener(() => _sharedProgress.value = _slideProgress.value);
    _sharedProgress.value = 0;
    _selected =
        app.configStore.current.mountedProfileIds.isNotEmpty ||
            app.localRoots.every((root) => !root.enabled)
        ? _Section.network
        : _Section.local;
    _built.add(_selected);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.initialError != null) {
        _notice(widget.initialError!);
      }
      if (mounted) {
        unawaited(_restore(_selected));
      }
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _slideProgress.dispose();
    _slideController.dispose();
    super.dispose();
  }

  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SPNotice(content: AppText(message)));
    }
  }

  Future<void> _restore(_Section section) async {
    if (!_restored.add(section)) return;
    if (section != _Section.network && section != _Section.local) return;
    final app = context.read<AppState>();
    final sourceId = app.navigationLocations.lastSource(
      section == _Section.local ? 'local' : 'network',
    );
    if (sourceId == null) return;
    final navigator = _keys[section]!.currentState;
    if (navigator == null || navigator.canPop()) return;
    if (section == _Section.local) {
      final root = app.localRoots
          .where((item) => item.sourceId == sourceId && item.enabled)
          .firstOrNull;
      if (root != null) {
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => BrowserPage(localRoot: root)),
        );
      }
      return;
    }
    if (!app.configStore.current.mountedProfileIds.contains(sourceId)) {
      return;
    }
    try {
      await app.activateMountedProfile(sourceId);
      if (mounted) {
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => const BrowserPage()),
        );
      }
    } on AppException catch (error) {
      _notice(error.message);
    }
  }

  void _select(_Section section, {bool restore = true}) {
    _hideTimer?.cancel();
    setState(() {
      _selected = section;
      _built.add(section);
      _expanded = false;
    });
    _slideController.reverse();
    if (restore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_restore(section));
      });
    } else {
      _restored.add(section);
    }
  }

  void _setExpanded(bool expanded) {
    if (_expanded == expanded) return;
    setState(() => _expanded = expanded);
    if (expanded) {
      _slideController.forward();
    } else {
      _slideController.reverse();
    }
  }

  void _enterTrigger() {
    _hoveringTrigger = true;
    _hideTimer?.cancel();
    _setExpanded(true);
  }

  void _leaveTrigger() {
    _hoveringTrigger = false;
    _scheduleHide();
  }

  void _enterSidebar() {
    _hoveringSidebar = true;
    _hideTimer?.cancel();
    _setExpanded(true);
  }

  void _leaveSidebar() {
    _hoveringSidebar = false;
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 220), () {
      if (mounted && !_hoveringTrigger && !_hoveringSidebar) {
        _setExpanded(false);
      }
    });
  }

  Future<void> _openItem(
    String sourceId,
    String parentPath, {
    String? revealName,
    MediaLibraryItem? libraryItem,
  }) async {
    final app = context.read<AppState>();
    final local = sourceId.startsWith('local:');
    final section = local ? _Section.local : _Section.network;
    final root = local
        ? app.localRoots
              .where((item) => item.sourceId == sourceId && item.enabled)
              .firstOrNull
        : null;
    if (local && root == null) {
      _notice('本地来源不可用');
      return;
    }
    if (!local) {
      try {
        await app.activateMountedProfile(sourceId);
      } on AppException catch (error) {
        _notice(error.message);
        return;
      }
    }
    _select(section, restore: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _keys[section]!.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => BrowserPage(
            localRoot: root,
            initialDirectoryPath: parentPath,
            initialRevealName: revealName,
            initialLibraryItem: libraryItem,
          ),
        ),
      );
    });
  }

  Widget _root(_Section section) => switch (section) {
    _Section.network => const NetworkStoragePage(),
    _Section.local => const LocalStoragePage(),
    _Section.library => GlobalMediaLibraryPage(
      onOpenItem: (item) =>
          _openItem(item.sourceId, item.parentPath, libraryItem: item),
    ),
    _Section.mounts => const MountManagementPage(),
    _Section.search => GlobalSearchPage(
      onOpenResult: (item) =>
          _openItem(item.sourceId, item.parentPath, revealName: item.name),
    ),
    _Section.settings => const SettingsPage(),
  };

  Widget _content() => IndexedStack(
    index: _selected.index,
    children: [
      for (final section in _Section.values)
        _built.contains(section)
            ? Navigator(
                key: _keys[section],
                onGenerateRoute: (_) =>
                    MaterialPageRoute<void>(builder: (_) => _root(section)),
              )
            : const SizedBox.shrink(),
    ],
  );

  Widget _sidebar() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mode = context
        .watch<AppState>()
        .configStore
        .current
        .appearance
        .sidebarMode;
    const entries = [
      (_Section.network, SPIcons.cloud, '网络文件夹'),
      (_Section.local, SPIcons.folder, '本地文件夹'),
      (_Section.mounts, SPIcons.hardDrive, '文件夹管理'),
      (_Section.library, SPIcons.library, '媒体中心'),
      (_Section.search, SPIcons.search, '搜索'),
      (_Section.settings, SPIcons.settings, '设置'),
    ];
    return Material(
      key: const Key('sidebar-surface'),
      color: theme.sidebarSurfaceColor,
      child: DecoratedBox(
        key: const Key('sidebar-edge'),
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: theme.glass.borderColor)),
        ),
        child: Column(
          children: [
            SizedBox(
              height: 44,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    key: const Key('sidebar-mode-toggle'),
                    tooltip: context.l10n.text('切换侧边栏显示模式'),
                    icon: Icon(
                      mode == SidebarDisplayMode.pinned
                          ? SPIcons.pin
                          : SPIcons.pinOff,
                    ),
                    onPressed: () async {
                      try {
                        await context.read<AppState>().setSidebarMode(
                          mode == SidebarDisplayMode.pinned
                              ? SidebarDisplayMode.autoHide
                              : SidebarDisplayMode.pinned,
                        );
                        if (mounted) _setExpanded(false);
                      } on AppException catch (error) {
                        _notice(error.message);
                      }
                    },
                  ),
                ),
              ),
            ),
            for (final (section, icon, label) in entries)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Container(
                  decoration:
                      section == _selected &&
                          theme.glass.enabled &&
                          theme.brightness == Brightness.dark
                      ? BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color.alphaBlend(
                                scheme.primary.withValues(alpha: 0.14),
                                scheme.primaryContainer,
                              ),
                              scheme.primaryContainer,
                            ],
                          ),
                          border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.3),
                          ),
                          borderRadius: BorderRadius.circular(9),
                          boxShadow: [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.14),
                              blurRadius: 14,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        )
                      : null,
                  child: Material(
                    color:
                        section == _selected &&
                            theme.glass.enabled &&
                            theme.brightness == Brightness.dark
                        ? Colors.transparent
                        : section == _selected
                        ? scheme.primaryContainer
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    child: ListTile(
                      key: Key('sidebar-${section.name}'),
                      dense: true,
                      leading: Icon(icon, size: 21),
                      title: AppText(label),
                      selected: section == _selected,
                      onTap: () => _select(section),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pinned =
        context.watch<AppState>().configStore.current.appearance.sidebarMode ==
        SidebarDisplayMode.pinned;
    if (pinned) {
      return Row(
        children: [
          SizedBox(width: _width, child: _sidebar()),
          Expanded(child: _content()),
        ],
      );
    }
    final content = _content();
    final sidebar = _sidebar();
    return AnimatedBuilder(
      animation: _slideProgress,
      builder: (context, _) {
        final visibleWidth =
            _triggerWidth + (_width - _triggerWidth) * _slideProgress.value;
        return Stack(
          children: [
            Positioned.fill(
              left: _triggerWidth,
              // 侧栏滑出时遮住其后方页面，保留与固定模式相同的窗口背景。
              child: ClipRect(
                key: const Key('sidebar-content-clip'),
                clipper: _SidebarContentClipper(visibleWidth - _triggerWidth),
                child: content,
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _hoverWidth,
              child: FocusableActionDetector(
                onShowFocusHighlight: (focused) {
                  if (focused) _setExpanded(true);
                },
                child: MouseRegion(
                  key: const Key('sidebar-hover-zone'),
                  onEnter: (_) => _enterTrigger(),
                  onExit: (_) => _leaveTrigger(),
                  child: Tooltip(
                    message: context.l10n.text('显示侧边栏'),
                    child: InkWell(
                      onTap: () => _setExpanded(true),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: visibleWidth - _width,
              top: 0,
              bottom: 0,
              width: _width,
              child: MouseRegion(
                onEnter: (_) => _enterSidebar(),
                onExit: (_) => _leaveSidebar(),
                child: sidebar,
              ),
            ),
            if (!_expanded)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: _triggerWidth,
                child: IgnorePointer(
                  child: ColoredBox(
                    key: const Key('sidebar-visible-strip'),
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.15),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SidebarContentClipper extends CustomClipper<Rect> {
  const _SidebarContentClipper(this.left);

  final double left;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    left.clamp(0.0, size.width).toDouble(),
    0,
    size.width,
    size.height,
  );

  @override
  bool shouldReclip(_SidebarContentClipper oldClipper) =>
      oldClipper.left != left;
}
