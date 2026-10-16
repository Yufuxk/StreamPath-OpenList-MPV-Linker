import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/errors/app_exception.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/local/film_catalog_store.dart';
import '../theme/glass_tokens.dart';
import '../theme/app_theme.dart';
import '../../data/models/film_playlist.dart';
import '../../data/models/media_source.dart';
import '../../domain/services/webdav_media_source_adapter.dart';
import '../../domain/services/windows_folder_picker.dart';
import '../../features/video_cache/video_cache_models.dart';
import '../../features/video_cache/video_cache_planner.dart';
import '../../features/video_cache/video_cache_service.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import 'directory_scroll_view.dart';
import 'film_detail_buttons.dart';
import 'film_artwork.dart';
import 'film_watch_menu.dart';
import 'glass_dialog.dart';
import 'glass_surface.dart';
import 'settings_group_card.dart';
import 'sp_dialog.dart';
import 'sp_icons.dart';
import 'sp_menu.dart';
import 'sp_notice.dart';

String videoCacheBytes(num bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble(), unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String _error(BuildContext context, Object error) {
  final message = error is VideoCacheException
      ? error.message
      : error is AppException
      ? error.message
      : '视频缓存操作失败';
  if (message.startsWith('缓存磁盘空间不足|')) {
    final parts = message.split('|');
    return context.l10n.format('缓存空间不足：需要 {required}，可用 {available}。', {
      'required': videoCacheBytes(int.parse(parts[1])),
      'available': videoCacheBytes(int.parse(parts[2])),
    });
  }
  return context.l10n.text(message);
}

Future<void> _action(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } on VideoCacheException catch (error) {
    if (context.mounted) _notice(context, error);
  } on AppException catch (error) {
    if (context.mounted) _notice(context, error);
  } on FilmCatalogException catch (error) {
    if (context.mounted) _notice(context, error);
  } on FileSystemException catch (error) {
    if (context.mounted) _notice(context, error);
  }
}

void _notice(BuildContext context, Object error) => ScaffoldMessenger.of(
  context,
).showSnackBar(SPNotice(content: Text(_error(context, error))));

Future<void> showVideoCacheDialog(
  BuildContext context,
  FilmCatalogController catalog,
  FilmPlaylistScope scope, {
  String? title,
  String? sourceId,
}) => _action(context, () async {
  final app = context.read<AppState>();
  final cache = await app.getVideoCache();
  final resources = scope.resource != null
      ? [scope.resource!]
      : scope.playlist != null
      ? <FilmResource>[]
      : await catalog.store.resources(
          workId: scope.workId,
          sourceId: sourceId ?? catalog.sourceId,
        );
  if (!context.mounted) return;
  final candidates = resources
      .where(
        (r) =>
            r.sourceKind != MediaSourceKind.local &&
            r.availability == 'present' &&
            (scope.season == null || r.season == scope.season),
      )
      .toList();
  final selected =
      scope.playlist?.sourceId ??
      (candidates.isEmpty
          ? null
          : await selectFilmActionSource(context, candidates));
  if (!context.mounted || selected == null) return;
  final groups = await catalog.store.cacheResourceGroups(selected, scope);
  if (!context.mounted || groups.isEmpty) return;
  final identity = await app.videoCacheIdentity(selected);
  final existing = groups
      .expand((g) => g)
      .every(
        (r) => cache.bundles.values.any(
          (b) =>
              b['source'] == selected &&
              b['path'] == r.path &&
              b['identity'] == identity,
        ),
      );
  if (!existing) await app.mountMediaConnectionIfConfigured(selected);
  final source = existing
      ? await app.videoCacheSource(selected)
      : app.directorySource(selected);
  if (source is! WebDavMediaSourceAdapter) {
    throw const VideoCacheException('缓存来源不可用');
  }
  if (!context.mounted) return;
  await showGlassDialog<void>(
    context: context,
    builder: (_) => VideoCacheDownloadDialog(
      cache: cache,
      source: source,
      groups: groups,
      title: title ?? groups.first.first.name,
      disc: groups.any((g) => g.any((r) => r.isDisc)),
    ),
  );
});

class VideoCacheDownloadDialog extends StatefulWidget {
  const VideoCacheDownloadDialog({
    super.key,
    required this.cache,
    required this.source,
    required this.groups,
    required this.title,
    required this.disc,
  });
  final VideoCacheService cache;
  final WebDavMediaSourceAdapter source;
  final List<List<FilmResource>> groups;
  final String title;
  final bool disc;
  @override
  State<VideoCacheDownloadDialog> createState() => _CacheDialogState();
}

class _CacheDialogState extends State<VideoCacheDownloadDialog> {
  late final _directory = TextEditingController(
    text: widget.cache.targetDirectory,
  );
  late final _selected = [for (final group in widget.groups) group.first];
  final _scroll = ScrollController();
  final _plans = <int, VideoCachePlan>{};
  final _errors = <int, Object>{};
  bool _busy = true;
  int _generation = 0;
  Object? _spaceError;
  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _generation++;
    _directory.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _plans.clear();
      _errors.clear();
      _spaceError = null;
    });
    final app = context.read<AppState>();
    final planner = VideoCachePlanner(
      widget.cache,
      widget.source,
      app.configStore.current.toPlayerConfig(),
      app.subtitleMatcher,
      app.webDavFontMatcher,
      identity: await app.videoCacheIdentity(widget.source.descriptor.sourceId),
    );
    final target = _directory.text.trim();
    for (var i = 0; i < _selected.length; i++) {
      if (!mounted || generation != _generation) return;
      try {
        final plan = await planner.plan(_selected[i], target);
        if (!mounted || generation != _generation) return;
        setState(() => _plans[i] = plan);
      } on VideoCacheException catch (e) {
        if (mounted && generation == _generation) {
          setState(() => _errors[i] = e);
        }
      } on AppException catch (e) {
        if (mounted && generation == _generation) {
          setState(() => _errors[i] = e);
        }
      } on FilmCatalogException catch (e) {
        if (mounted && generation == _generation) {
          setState(() => _errors[i] = e);
        }
      } on FileSystemException catch (e) {
        if (mounted && generation == _generation) {
          setState(() => _errors[i] = e);
        }
      }
    }
    try {
      await widget.cache.checkSpace(_plans.values.toList());
    } on VideoCacheException catch (e) {
      if (mounted && generation == _generation) _spaceError = e;
    } on FileSystemException catch (e) {
      if (mounted && generation == _generation) _spaceError = e;
    }
    if (mounted && generation == _generation) setState(() => _busy = false);
  }

  Future<void> _choose() async {
    final selected = await WindowsFolderPicker.pickDirectory(
      title: context.l10n.text('选择视频缓存目录'),
    );
    if (!mounted || selected == null) return;
    _directory.text = selected;
    await _prepare();
  }

  @override
  Widget build(BuildContext context) {
    final unique = {
      for (final plan in _plans.values)
        for (final file in plan.files) file.id: file,
    };
    final size = unique.values.fold<int>(0, (total, file) => total + file.size);
    return SPDialog(
      key: const Key('video-cache-dialog'),
      title: const AppText('缓存视频'),
      content: SizedBox(
        width: 600,
        height: math.min(500, MediaQuery.sizeOf(context).height * .58),
        child: DirectoryScrollView(
          controller: _scroll,
          builder: (controller) => ListView(
            controller: controller,
            children: [
              Text(
                widget.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                widget.source.descriptor.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _directory,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: context.l10n.text('本次缓存目录'),
                  prefixIcon: const Icon(SPIcons.folder),
                  suffixIcon: IconButton(
                    onPressed: _busy ? null : _choose,
                    icon: const Icon(SPIcons.folder),
                    tooltip: context.l10n.text('选择视频缓存目录'),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const AppText('本次选择不会更改设置中的默认目录。'),
              if (widget.disc)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: AppText('蓝光按整盘缓存，包含盘内其他集数，并保留原有菜单。'),
                ),
              for (var i = 0; i < widget.groups.length; i++) ...[
                const SizedBox(height: 8),
                if (widget.groups[i].length > 1)
                  SPDropdownButtonFormField<FilmResource>(
                    initialValue: _selected[i],
                    decoration: InputDecoration(
                      labelText: context.l10n.text('缓存版本'),
                    ),
                    items: [
                      for (final r in widget.groups[i])
                        DropdownMenuItem(value: r, child: Text(r.name)),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null) {
                              _selected[i] = value;
                              unawaited(_prepare());
                            }
                          },
                  )
                else
                  Text(
                    _selected[i].name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (_errors[i] case final error?)
                  Text(
                    _error(context, error),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  )
                else if (_plans[i] case final plan?) ...[
                  Text(
                    widget.cache.complete(plan.bundle)
                        ? context.l10n.text('已缓存')
                        : '${plan.files.length} ${context.l10n.text('个文件')} · ${videoCacheBytes(plan.size)}',
                  ),
                  if ((plan.bundle['attachments'] as List?)?.isNotEmpty == true)
                    Text(
                      context.l10n.format('附件：{files}', {
                        'files': plan.files
                            .where(
                              (f) => (plan.bundle['attachments'] as List)
                                  .contains(f.id),
                            )
                            .map((f) => f.path.split('/').last)
                            .join(' · '),
                      }),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ],
              const SizedBox(height: 12),
              if (_busy)
                const LinearProgressIndicator(
                  minHeight: 6,
                  borderRadius: BorderRadius.all(Radius.circular(999)),
                )
              else
                Text(
                  '${context.l10n.text('合计')} ${unique.length} ${context.l10n.text('个文件')} · ${videoCacheBytes(size)}',
                ),
              if (_spaceError case final error?)
                Text(
                  _error(context, error),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const AppText('取消'),
        ),
        TextButton(
          onPressed: _busy ? null : _prepare,
          child: const AppText('重新检查'),
        ),
        FilledButton(
          key: const Key('confirm-video-cache'),
          onPressed: _busy || _spaceError != null || _plans.isEmpty
              ? null
              : () => _action(context, () async {
                  setState(() => _busy = true);
                  try {
                    await widget.cache.enqueue(_plans.values.toList());
                    if (context.mounted) Navigator.pop(context);
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                }),
          child: AppText(_errors.isEmpty ? '开始缓存' : '仅缓存可用项目'),
        ),
      ],
    );
  }
}

class VideoCacheOverlay extends StatefulWidget {
  const VideoCacheOverlay({super.key, required this.child});
  final Widget child;
  @override
  State<VideoCacheOverlay> createState() => _VideoCacheOverlayState();
}

class _VideoCacheOverlayState extends State<VideoCacheOverlay>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  final _panelFocus = FocusScopeNode(debugLabel: 'Video cache panel');
  late final AnimationController _expansion;
  late final Animation<double> _reveal;

  @override
  void initState() {
    super.initState();
    _expansion =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 240),
          reverseDuration: const Duration(milliseconds: 200),
        )..addStatusListener((status) {
          if (status == AnimationStatus.dismissed) setState(() {});
        });
    _reveal = _expansion.drive(CurveTween(curve: Curves.easeOutCubic));
  }

  void _setExpanded(bool expanded) {
    setState(() => _expanded = expanded);
    if (expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _expanded) _panelFocus.requestFocus();
      });
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _expansion.value = expanded ? 1 : 0;
    } else if (expanded) {
      _expansion.forward();
    } else {
      _expansion.reverse();
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (_expanded &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _setExpanded(false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _panelFocus.dispose();
    _expansion.dispose();
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<VideoCacheService?>(
    valueListenable: context.read<AppState>().videoCacheReady,
    builder: (context, cache, _) {
      if (cache == null) return widget.child;
      return ValueListenableBuilder<int>(
        valueListenable: cache.changes,
        child: widget.child,
        builder: (context, _, child) {
          final pending = cache.files.values.where((f) => f.pending).toList();
          final files = _pendingCacheBundles(cache)
              .expand((bundle) => bundle['files'] as List)
              .toSet()
              .map((id) => cache.files[id]!);
          final total = files.fold<int>(0, (n, f) => n + f.size);
          final received = files.fold<int>(0, (n, f) => n + f.received);
          final actionStyle = FilmDetailActionButton.styleOf(context);
          return LayoutBuilder(
            builder: (context, constraints) {
              final bottom = math.min(
                96.0,
                math.max(16.0, constraints.maxHeight - 76),
              );
              return Stack(
                children: [
                  Positioned.fill(child: child!),
                  if (pending.isNotEmpty)
                    Positioned(
                      right: 24,
                      bottom: bottom,
                      child: TapRegion(
                        onTapOutside: (_) {
                          if (_expanded) _setExpanded(false);
                        },
                        child: RepaintBoundary(
                          child: Focus(
                            skipTraversal: true,
                            onKeyEvent: _handleKeyEvent,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_expanded || !_expansion.isDismissed)
                                  IgnorePointer(
                                    ignoring: !_expanded,
                                    child: ExcludeSemantics(
                                      excluding: !_expanded,
                                      child: FocusScope(
                                        node: _panelFocus,
                                        canRequestFocus: _expanded,
                                        child: ClipRect(
                                          key: const Key(
                                            'video-cache-panel-reveal',
                                          ),
                                          clipper: _VideoCachePanelClipper(
                                            _reveal,
                                          ),
                                          child: SizedBox(
                                            width: math.min(
                                              520,
                                              math.max(
                                                0,
                                                constraints.maxWidth - 48,
                                              ),
                                            ),
                                            height: math.min(
                                              560,
                                              math.min(
                                                MediaQuery.sizeOf(
                                                      context,
                                                    ).height *
                                                    .6,
                                                math.max(
                                                  0,
                                                  constraints.maxHeight -
                                                      bottom -
                                                      88,
                                                ),
                                              ),
                                            ),
                                            child: Theme(
                                              data:
                                                  AppTheme.videoCachePanelTheme(
                                                    Theme.of(context),
                                                  ),
                                              child: GlassSurface(
                                                key: const Key(
                                                  'video-cache-panel',
                                                ),
                                                level: GlassSurfaceLevel.raised,
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                clipBehavior: Clip.antiAlias,
                                                blur: true,
                                                blurSigma: AppTheme
                                                    .videoCacheBlurSigma,
                                                child: Column(
                                                  children: [
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets.fromLTRB(
                                                            20,
                                                            12,
                                                            12,
                                                            0,
                                                          ),
                                                      child: Row(
                                                        children: [
                                                          Expanded(
                                                            child: AppText(
                                                              '视频缓存',
                                                              style:
                                                                  Theme.of(
                                                                        context,
                                                                      )
                                                                      .textTheme
                                                                      .titleLarge,
                                                            ),
                                                          ),
                                                          IconButton(
                                                            key: const Key(
                                                              'video-cache-collapse',
                                                            ),
                                                            style: const ButtonStyle(
                                                              backgroundColor:
                                                                  WidgetStatePropertyAll(
                                                                    Colors
                                                                        .transparent,
                                                                  ),
                                                              overlayColor:
                                                                  WidgetStatePropertyAll(
                                                                    Colors
                                                                        .transparent,
                                                                  ),
                                                              side:
                                                                  WidgetStatePropertyAll(
                                                                    BorderSide
                                                                        .none,
                                                                  ),
                                                              shape: WidgetStatePropertyAll(
                                                                CircleBorder(),
                                                              ),
                                                            ),
                                                            onPressed: () =>
                                                                _setExpanded(
                                                                  false,
                                                                ),
                                                            icon: const Icon(
                                                              SPIcons
                                                                  .chevronDown,
                                                            ),
                                                            tooltip: context
                                                                .l10n
                                                                .text('收起缓存浮窗'),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    Expanded(
                                                      child: _CacheRows(
                                                        cache: cache,
                                                        completed: false,
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
                                const SizedBox(height: 12),
                                Tooltip(
                                  message: context.l10n.text('视频缓存'),
                                  child: SizedBox(
                                    width: 52,
                                    height: 52,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        FilmDetailActionSurface(
                                          radius: 999,
                                          child: IconButton(
                                            key: const Key(
                                              'video-cache-floating-button',
                                            ),
                                            style: ButtonStyle(
                                              backgroundColor:
                                                  actionStyle.backgroundColor,
                                              side: actionStyle.side,
                                              shape:
                                                  const WidgetStatePropertyAll(
                                                    CircleBorder(),
                                                  ),
                                              fixedSize:
                                                  const WidgetStatePropertyAll(
                                                    Size(44, 44),
                                                  ),
                                            ),
                                            onPressed: () =>
                                                _setExpanded(!_expanded),
                                            icon: const Icon(SPIcons.download),
                                          ),
                                        ),
                                        Positioned.fill(
                                          child: IgnorePointer(
                                            child: CircularProgressIndicator(
                                              value: total == 0
                                                  ? 0
                                                  : (received / total).clamp(
                                                      0,
                                                      1,
                                                    ),
                                              strokeWidth: 3,
                                              strokeCap: StrokeCap.round,
                                              backgroundColor: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: .10),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      );
    },
  );
}

class _VideoCachePanelClipper extends CustomClipper<Rect> {
  _VideoCachePanelClipper(this.animation) : super(reclip: animation);

  final Animation<double> animation;

  @override
  Rect getClip(Size size) {
    final value = animation.value;
    // 同步揭示原阴影，避免运动结束时才出现外沿；内容布局始终固定。
    final shadow = 32 * value;
    return Rect.fromLTRB(
      size.width * (1 - value) - shadow,
      size.height * (1 - value) - shadow,
      size.width + shadow,
      size.height + shadow,
    );
  }

  @override
  bool shouldReclip(_VideoCachePanelClipper oldClipper) =>
      animation != oldClipper.animation;
}

Iterable<Map<String, dynamic>> _pendingCacheBundles(VideoCacheService cache) =>
    cache.bundles.values.where(
      (bundle) =>
          (bundle['files'] as List).any((id) => cache.files[id]!.pending),
    );

class _CacheRows extends StatefulWidget {
  const _CacheRows({required this.cache, required this.completed});
  final VideoCacheService cache;
  final bool completed;
  @override
  State<_CacheRows> createState() => _CacheRowsState();
}

class _CacheRowsState extends State<_CacheRows> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cache = widget.cache;
    final bundles =
        (widget.completed ? cache.bundles.values : _pendingCacheBundles(cache))
            .toList();
    final theme = Theme.of(context);
    return DirectoryScrollView(
      controller: _scroll,
      builder: (controller) => ListView.builder(
        controller: controller,
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: bundles.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) return _CacheSummary(cache: cache, bundles: bundles);
          final bundle = bundles[index - 1];
          final files = (bundle['files'] as List)
              .map((id) => cache.files[id]!)
              .toList();
          final current = files.where((f) => !f.complete).firstOrNull;
          final size = files.fold<int>(0, (n, f) => n + f.size),
              received = files.fold<int>(0, (n, f) => n + f.received);
          final speed = files.fold<double>(0, (n, f) => n + f.speed);
          final state = current == null
              ? 'completed'
              : ['paused', 'cancelled'].contains(bundle['state'])
              ? bundle['state'] as String
              : current.state;
          final resumable = ['paused', 'failed', 'cancelled'].contains(state);
          final actions = Wrap(
            spacing: 4,
            children: [
              if (current != null)
                IconButton(
                  key: ValueKey('video-cache-toggle-${bundle['id']}'),
                  tooltip: context.l10n.text(resumable ? '继续下载' : '暂停下载'),
                  onPressed: () => _action(
                    context,
                    () => resumable
                        ? cache.resume(bundle['id'] as String)
                        : cache.pause(bundle['id'] as String),
                  ),
                  icon: Icon(
                    resumable ? SPIcons.play : SPIcons.pause,
                    size: 18,
                  ),
                ),
              IconButton(
                key: ValueKey('video-cache-delete-${bundle['id']}'),
                tooltip: context.l10n.text('删除'),
                onPressed: () => _action(context, () async {
                  final confirmed = await showGlassDialog<bool>(
                    context: context,
                    builder: (context) => Theme(
                      data: AppTheme.videoCachePanelTheme(Theme.of(context)),
                      child: SPDialog(
                        title: const AppText('删除视频缓存？'),
                        content: const AppText('将删除选中视频的缓存及不再使用的附件。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const AppText('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const AppText('删除'),
                          ),
                        ],
                      ),
                    ),
                  );
                  if (confirmed == true && context.mounted) {
                    await cache.delete(
                      bundle['id'] as String,
                      protectedPaths: context
                          .read<AppState>()
                          .cachedPlaybackFiles,
                    );
                  }
                }),
                icon: const Icon(SPIcons.delete, size: 18),
              ),
            ],
          );
          return Padding(
            key: ValueKey('video-cache-task-${bundle['id']}'),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact =
                    constraints.maxWidth < 380 ||
                    MediaQuery.textScalerOf(context).scale(14) > 21;
                final title = Text(
                  bundle['name'] as String,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                );
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CachePoster(
                      key: ValueKey(bundle['id']),
                      source: bundle['source'] as String,
                      path: bundle['path'] as String,
                      kind: bundle['kind'] as String,
                    ),
                    SizedBox(width: compact ? 10 : 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (compact)
                            title
                          else
                            Row(
                              children: [
                                Expanded(child: title),
                                actions,
                              ],
                            ),
                          if (current != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              current.path,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            value: size == 0
                                ? 1
                                : (received / size).clamp(0, 1),
                            minHeight: 6,
                            backgroundColor: theme.colorScheme.onSurface
                                .withValues(alpha: .10),
                            borderRadius: BorderRadius.circular(999),
                            stopIndicatorColor: Colors.transparent,
                            trackGap: 0,
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 16,
                            runSpacing: 4,
                            alignment: WrapAlignment.spaceBetween,
                            children: [
                              AppText(switch (state) {
                                'completed' => '已缓存',
                                'paused' => '缓存下载已暂停',
                                'cancelled' => '已取消',
                                'failed' => '缓存下载失败',
                                'waiting' => '等待重试',
                                'queued' =>
                                  cache.playbackSuspended
                                      ? '在线播放期间已自动暂停下载'
                                      : '等待下载',
                                _ =>
                                  cache.playbackSuspended
                                      ? '在线播放期间已自动暂停下载'
                                      : '正在缓存',
                              }, style: theme.textTheme.bodySmall),
                              Text(
                                '${videoCacheBytes(received)} / ${videoCacheBytes(size)} · ${size == 0 ? 100 : (received / size * 100).clamp(0, 100).round()}%',
                                style: theme.textTheme.bodySmall,
                              ),
                              if (speed > 0 && !cache.playbackSuspended)
                                Text(
                                  '${videoCacheBytes(speed)}/s',
                                  style: theme.textTheme.bodySmall,
                                ),
                            ],
                          ),
                          if (current?.error case final error?) ...[
                            const SizedBox(height: 4),
                            Text(
                              _error(context, VideoCacheException(error)),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ],
                          if (widget.completed) ...[
                            const SizedBox(height: 8),
                            SelectionArea(
                              contextMenuBuilder: (context, state) =>
                                  buildSPSelectionToolbar(
                                    context,
                                    state.contextMenuAnchors,
                                    state.contextMenuButtonItems,
                                  ),
                              child: Tooltip(
                                message: bundle['root'] as String,
                                child: Text(
                                  bundle['root'] as String,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ),
                          ],
                          if (compact)
                            Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: actions,
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _CachePoster extends StatefulWidget {
  const _CachePoster({
    super.key,
    required this.source,
    required this.path,
    required this.kind,
  });
  final String source, path, kind;

  @override
  State<_CachePoster> createState() => _CachePosterState();
}

class _CachePosterState extends State<_CachePoster> {
  late final _poster = _loadPoster();

  Future<({FilmCatalogController catalog, String? path})> _loadPoster() async {
    final catalog = await context.read<AppState>().getFilmCatalog();
    final store = catalog.store;
    final resource = await store.resourceAt(widget.source, widget.path);
    final workId = resource?.workId;
    return (
      catalog: catalog,
      path: workId == null ? null : (await store.work(workId))?.posterPath,
    );
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<({FilmCatalogController catalog, String? path})>(
        future: _poster,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) return _CachePlaceholder(kind: widget.kind);
          return FilmArtwork(
            cache: data.catalog.images,
            path: data.path,
            target: 'w92',
            width: 44,
            height: 66,
            borderRadius: 8,
            placeholder: _CachePlaceholder(kind: widget.kind),
          );
        },
      );
}

class _CachePlaceholder extends StatelessWidget {
  const _CachePlaceholder({required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 44,
      height: 66,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          colors.primary.withValues(alpha: .12),
          colors.surfaceContainerHighest,
        ),
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        kind == 'video' ? SPIcons.video : SPIcons.disc,
        color: colors.primary,
      ),
    );
  }
}

class _CacheSummary extends StatelessWidget {
  const _CacheSummary({required this.cache, required this.bundles});
  final VideoCacheService cache;
  final List<Map<String, dynamic>> bundles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final files = bundles
        .expand((bundle) => bundle['files'] as List)
        .toSet()
        .map((id) => cache.files[id]!);
    final total = files.fold<int>(0, (sum, file) => sum + file.size);
    final received = files.fold<int>(0, (sum, file) => sum + file.received);
    final speed = cache.playbackSuspended
        ? 0
        : files
              .where((file) => file.state == 'downloading')
              .fold<double>(0, (sum, file) => sum + file.speed);
    var active = 0;
    var waiting = 0;
    for (final bundle in bundles) {
      if (['paused', 'cancelled'].contains(bundle['state'])) continue;
      final files = (bundle['files'] as List).map((id) => cache.files[id]!);
      if (!cache.playbackSuspended &&
          files.any(
            (file) => file.state == 'downloading' || file.state == 'finalizing',
          )) {
        active++;
      } else if (files.any(
        (file) => file.state == 'queued' || file.state == 'waiting',
      )) {
        waiting++;
      }
    }
    final progress = total == 0 ? 0.0 : (received / total).clamp(0.0, 1.0);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.glass.dividerColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n
                  .format('{active} 项下载中 · {waiting} 项等待 · {total} 项任务', {
                    'active': '$active',
                    'waiting': '$waiting',
                    'total': '${bundles.length}',
                  }),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: AppText('总缓存进度', style: theme.textTheme.bodyMedium),
                ),
                Text(
                  '${(progress * 100).round()}%',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              key: const Key('video-cache-total-progress'),
              value: progress,
              minHeight: 6,
              backgroundColor: theme.colorScheme.onSurface.withValues(
                alpha: .10,
              ),
              borderRadius: BorderRadius.circular(999),
              stopIndicatorColor: Colors.transparent,
              trackGap: 0,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Text(
                  '${videoCacheBytes(speed)}/s',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  '${videoCacheBytes(received)} / ${videoCacheBytes(total)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            if (cache.playbackSuspended && cache.hasPending) ...[
              const SizedBox(height: 8),
              AppText('在线播放期间已自动暂停下载', style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class VideoCacheSettingsCard extends StatelessWidget {
  const VideoCacheSettingsCard({super.key});
  @override
  Widget build(BuildContext context) => Theme(
    data: AppTheme.videoCachePanelTheme(Theme.of(context)),
    child: Builder(
      builder: (context) => ValueListenableBuilder<VideoCacheService?>(
        valueListenable: context.read<AppState>().videoCacheReady,
        builder: (context, cache, _) {
          return SettingsGroupCard(
            icon: SPIcons.download,
            title: '视频离线缓存',
            description: '缓存完整视频及匹配附件，播放时优先使用本地文件。',
            child: cache == null
                ? _content(context, null)
                : ValueListenableBuilder<int>(
                    valueListenable: cache.changes,
                    builder: (context, _, _) => _content(context, cache),
                  ),
          );
        },
      ),
    ),
  );

  Widget _content(BuildContext context, VideoCacheService? cache) {
    final app = context.read<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(cache?.targetDirectory ?? app.videoCacheDirectory),
        const SizedBox(height: 8),
        const AppText('普通缓存清理保留视频下载；修改默认目录只影响新任务。'),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: () => _action(context, () async {
                final selected = await WindowsFolderPicker.pickDirectory(
                  title: context.l10n.text('选择视频缓存目录'),
                );
                if (selected != null) {
                  await (await app.getVideoCache()).saveDirectory(selected);
                }
              }),
              child: const AppText('选择视频缓存目录'),
            ),
            TextButton(
              onPressed: () => _action(
                context,
                () async => (await app.getVideoCache()).saveDirectory(null),
              ),
              child: const AppText('恢复默认目录'),
            ),
            FilledButton(
              onPressed: () => _action(context, () async {
                final cache = await app.getVideoCache();
                if (!context.mounted) return;
                await showGlassDialog<void>(
                  context: context,
                  builder: (context) => Theme(
                    data: AppTheme.videoCachePanelTheme(Theme.of(context)),
                    child: SPDialog(
                      title: const AppText('管理视频缓存'),
                      content: SizedBox(
                        width: 620,
                        height: MediaQuery.sizeOf(context).height * .6,
                        child: ValueListenableBuilder<int>(
                          valueListenable: cache.changes,
                          builder: (context, _, _) =>
                              _CacheRows(cache: cache, completed: true),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const AppText('关闭'),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              child: const AppText('管理视频缓存'),
            ),
          ],
        ),
      ],
    );
  }
}
