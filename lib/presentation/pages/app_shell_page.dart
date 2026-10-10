import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/film_catalog_item.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/glass_tokens.dart';
import '../widgets/sp_icons.dart';
import '../widgets/sp_notice.dart';
import '../widgets/window_title_bar.dart';
import '../controllers/film_catalog_controller.dart';
import 'browser_page.dart';
import 'film_media_center_page.dart';
import 'film_library_shell.dart';
import 'folders_page.dart';
import 'settings_page.dart';

enum _Section { films, folders, library, settings }

/// 浏览分支保持挂载，使切换侧边栏不会停止播放监控。
class AppShellPage extends StatefulWidget {
  const AppShellPage({super.key, this.initialError});
  final String? initialError;

  @override
  State<AppShellPage> createState() => _AppShellPageState();
}

class _AppShellPageState extends State<AppShellPage>
    with SingleTickerProviderStateMixin {
  static const _slideDuration = WindowTitleBar.sidebarSlideDuration;
  final _settingsKey = GlobalKey<SettingsPageState>();
  final _filmShellKey = GlobalKey<FilmLibraryShellState>();
  FilmCatalogController? _filmTasks;
  int _filmCompletion = 0;
  bool _watchingFilms = false;

  Future<void> _watchFilmTasks() async {
    if (_watchingFilms) return;
    _watchingFilms = true;
    try {
      final catalog = await context.read<AppState>().getFilmCatalog();
      if (!mounted) return;
      _filmTasks = catalog;
      _filmCompletion = catalog.scrapeCompletion;
      catalog.taskChanges.addListener(_filmTasksChanged);
    } on FileSystemException {
      _watchingFilms = false;
      _notice('影视目录库操作失败');
    } on DatabaseException {
      _watchingFilms = false;
      _notice('影视目录库操作失败');
    } on FilmCatalogException {
      _watchingFilms = false;
      _notice('影视目录库操作失败');
    }
  }

  void _filmTasksChanged() {
    final completion = _filmTasks!.scrapeCompletion;
    if (completion == _filmCompletion) return;
    _filmCompletion = completion;
    _notice('刮削完成');
  }

  final _keys = {
    for (final section in _Section.values) section: GlobalKey<NavigatorState>(),
  };
  final Set<_Section> _built = {};
  late final Map<_Section, NavigatorObserver> _headerObservers;
  final _headerHeights = {
    for (final section in _Section.values) section: _rootHeaderHeight(section),
  };
  final _detailChrome = {
    for (final section in _Section.values)
      section: ValueNotifier<double?>(null),
  };
  late _Section _selected;
  double _settingsNavigationHeight = 0;
  bool _expanded = false;
  bool _hoveringTrigger = false;
  bool _hoveringSidebar = false;
  Timer? _hideTimer;
  late final AnimationController _slideController;
  late final CurvedAnimation _slideProgress;

  @override
  void initState() {
    super.initState();
    _headerObservers = {
      for (final section in _Section.values)
        section: _ShellHeaderObserver((route) => _pageChanged(section, route)),
    };
    for (final chrome in _detailChrome.values) {
      chrome.addListener(_detailChromeChanged);
    }
    _slideController = AnimationController(
      vsync: this,
      duration: _slideDuration,
    );
    _slideProgress = CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _selected = _Section.films;
    _built.add(_selected);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final app = context.read<AppState>();
        app.onImplicitVideoError = _notice;
        unawaited(app.restoreImplicitVideoControls());
        unawaited(_watchFilmTasks());
      }
      if (mounted && widget.initialError != null) {
        _notice(widget.initialError!);
      }
    });
  }

  @override
  void dispose() {
    for (final chrome in _detailChrome.values) {
      chrome.dispose();
    }
    _filmTasks?.taskChanges.removeListener(_filmTasksChanged);
    _hideTimer?.cancel();
    _slideProgress.dispose();
    _slideController.dispose();
    super.dispose();
  }

  void _detailChromeChanged() {
    final progress = _detailChrome[_selected]!.value;
    final shared = context.read<AppState>().filmDetailChrome;
    final wasImmersive = shared.value != null;
    shared.value = progress;
    if (wasImmersive != (progress != null)) {
      _hideTimer?.cancel();
      _expanded = false;
      _slideController.reverse();
      setState(() {});
    }
  }

  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SPNotice(content: AppText(message)));
    }
  }

  void _select(_Section section) {
    if (section == _Section.films || section == _Section.settings) {
      unawaited(_watchFilmTasks());
    }
    _hideTimer?.cancel();
    setState(() {
      _selected = section;
      _built.add(section);
      _expanded = false;
      _hoveringTrigger = false;
      _hoveringSidebar = false;
    });
    _slideController.reverse();
    context.read<AppState>().filmLibraryActive.value =
        section == _Section.films;
    context.read<AppState>().mediaSourcesVisible = section == _Section.folders;
    _detailChromeChanged();
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
    const section = _Section.folders;
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
    if (!mounted) return;
    _select(section);
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
    _Section.folders => FoldersPage(
      onOpenResult: (item) =>
          _openItem(item.sourceId, item.parentPath, revealName: item.name),
    ),
    _Section.library => FilmMediaCenterPage(
      onOpenItem: (item) => _filmShellKey.currentState!.play(item),
      onContinueSelected: (record) =>
          _filmShellKey.currentState!.continuePlaying(record),
      onContinueMenu: (record, position) =>
          _filmShellKey.currentState!.showPlaybackMenu(record, position),
      onOpenLegacyItem: (item) =>
          _openItem(item.sourceId, item.parentPath, libraryItem: item),
    ),
    _Section.films => FilmLibraryShell(
      key: _filmShellKey,
      sidebarInset: WindowTitleBar.compactSidebarWidth,
    ),
    _Section.settings => SettingsPage(
      key: _settingsKey,
      onNavigationHeight: (height) {
        if (mounted && height != _settingsNavigationHeight) {
          setState(() => _settingsNavigationHeight = height);
        }
      },
    ),
  };

  Widget _content() => IndexedStack(
    index: _selected.index,
    children: [
      for (final section in _Section.values)
        _built.contains(section)
            ? ListenableProvider<ValueNotifier<double?>>.value(
                value: _detailChrome[section]!,
                child: Navigator(
                  key: _keys[section],
                  observers: [_headerObservers[section]!],
                  onGenerateInitialRoutes: (_, _) => [
                    MaterialPageRoute<void>(builder: (_) => _root(section)),
                  ],
                  onGenerateRoute: (_) =>
                      MaterialPageRoute<void>(builder: (_) => _root(section)),
                ),
              )
            : const SizedBox.shrink(),
    ],
  );

  static double _rootHeaderHeight(_Section section) => switch (section) {
    _Section.folders || _Section.library => 96,
    _Section.films || _Section.settings => 48,
  };

  void _pageChanged(_Section section, PageRoute<dynamic> route) {
    final height = route.isFirst
        ? _rootHeaderHeight(section)
        : section == _Section.folders &&
              route.settings.name != FoldersPage.searchRouteName
        ? Theme.of(context).appBarTheme.toolbarHeight ?? kToolbarHeight
        : 48.0;
    if (_headerHeights[section] == height) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _headerHeights[section] = height);
    });
  }

  Widget _sidebar({bool floating = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(28);
    const entries = [
      (_Section.films, SPIcons.video, '影视库'),
      (_Section.folders, SPIcons.folder, '文件夹'),
      (_Section.library, SPIcons.library, '媒体中心'),
      (_Section.settings, SPIcons.settings, '设置'),
    ];
    return SizedBox.expand(
      key: const Key('sidebar-rail'),
      child: LayoutBuilder(
        builder: (context, constraints) => Padding(
          // 补偿窗口栏占用的高度，使所有分支按整个窗口居中。
          padding: EdgeInsets.fromLTRB(
            4,
            16,
            4,
            16 + MediaQuery.sizeOf(context).height - constraints.maxHeight,
          ),
          child: Align(
            alignment: Alignment.center,
            child: MouseRegion(
              onEnter: floating ? (_) => _enterSidebar() : null,
              onExit: floating ? (_) => _leaveSidebar() : null,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .18),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: radius,
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Material(
                      key: const Key('sidebar-surface'),
                      color: theme.sidebarSurfaceColor.withValues(
                        alpha: theme.glass.enabled
                            ? theme.brightness == Brightness.dark
                                  ? .28
                                  : .44
                            : theme.brightness == Brightness.dark
                            ? .48
                            : .64,
                      ),
                      child: DecoratedBox(
                        key: const Key('sidebar-edge'),
                        position: DecorationPosition.foreground,
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          border: Border.all(
                            color: scheme.onSurface.withValues(alpha: .14),
                          ),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              scheme.onSurface.withValues(alpha: .07),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final (section, icon, label) in entries)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 3,
                                  ),
                                  child: Tooltip(
                                    message: context.l10n.text(label),
                                    excludeFromSemantics: true,
                                    child: Semantics(
                                      label: context.l10n.text(label),
                                      button: true,
                                      selected: section == _selected,
                                      child: Material(
                                        color: section == _selected
                                            ? scheme.primaryContainer
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(24),
                                        child: InkWell(
                                          key: Key('sidebar-${section.name}'),
                                          borderRadius: BorderRadius.circular(
                                            24,
                                          ),
                                          onTap: () => _select(section),
                                          child: SizedBox(
                                            height: 48,
                                            child: Center(
                                              child: Icon(
                                                icon,
                                                size: 24,
                                                color: section == _selected
                                                    ? scheme.primary
                                                    : scheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const width = WindowTitleBar.compactSidebarWidth;
    final immersive = _detailChrome[_selected]!.value != null;
    final pinned = !immersive;
    if (pinned && _selected == _Section.films) {
      return Stack(
        children: [
          Positioned.fill(child: _content()),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: width,
            child: _sidebar(),
          ),
        ],
      );
    }
    if (pinned) {
      final theme = Theme.of(context);
      final headerHeight = _headerHeights[_selected]!;
      return Row(
        children: [
          SizedBox(
            width: width,
            child: ColoredBox(
              color: theme.scaffoldBackgroundColor,
              child: Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: headerHeight,
                    child: Material(
                      key: const Key('sidebar-header-extension'),
                      color: theme.appBarTheme.backgroundColor,
                      shape: theme.appBarTheme.shape,
                    ),
                  ),
                  if (_selected == _Section.settings)
                    Positioned(
                      top: headerHeight,
                      left: 0,
                      right: 0,
                      height: _settingsNavigationHeight,
                      child: DecoratedBox(
                        key: const Key('sidebar-settings-navigation-extension'),
                        decoration: BoxDecoration(
                          color: theme.glass.chromeSurface,
                          border: Border(
                            bottom: BorderSide(color: theme.glass.dividerColor),
                          ),
                        ),
                      ),
                    ),
                  _sidebar(),
                ],
              ),
            ),
          ),
          Expanded(child: _content()),
        ],
      );
    }
    final content = _content();
    final sidebar = _sidebar(floating: true);
    return AnimatedBuilder(
      animation: _slideProgress,
      builder: (context, _) {
        final visibleWidth = width * _slideProgress.value;
        return Stack(
          children: [
            Positioned.fill(
              left: 0,
              child: ClipRect(
                key: const Key('sidebar-content-clip'),
                child: content,
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 8,
              child: FocusableActionDetector(
                onShowFocusHighlight: (focused) {
                  if (focused) _setExpanded(true);
                },
                child: MouseRegion(
                  key: const Key('sidebar-hover-zone'),
                  onEnter: (_) => _enterTrigger(),
                  onExit: (_) => _leaveTrigger(),
                  child: Semantics(
                    label: context.l10n.text('显示侧边栏'),
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _setExpanded(true),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: visibleWidth - width,
              top: 0,
              bottom: 0,
              width: width,
              child: sidebar,
            ),
          ],
        );
      },
    );
  }
}

class _ShellHeaderObserver extends NavigatorObserver {
  _ShellHeaderObserver(this.onPageChanged);
  final void Function(PageRoute<dynamic>) onPageChanged;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    if (topRoute is PageRoute<dynamic>) onPageChanged(topRoute);
  }
}
