import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local/global_search_index.dart';
import '../../data/models/local_root_config.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/server_profile.dart';
import '../../domain/services/openlist_api_client.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../widgets/clipboard_history_menu.dart';
import '../widgets/sp_icons.dart';

typedef OpenGlobalSearchResult =
    Future<void> Function(GlobalSearchResult result);

/// 跨挂载搜索；每个来源的索引状态独立展示。
class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({super.key, required this.onOpenResult});
  final OpenGlobalSearchResult onOpenResult;

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  final _controller = TextEditingController();
  final Map<String, String> _states = {};
  final Map<String, ServerProfile> _serverProfiles = {};
  GlobalSearchIndex? _index;
  List<GlobalSearchResult> _results = const [];
  Timer? _debounce;
  int _searchGeneration = 0;
  bool _loading = true;
  bool _indexing = false;
  bool _truncated = false;
  String? _sourceSignature;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final index = await context.read<AppState>().getGlobalSearchIndex();
      if (!mounted) {
        return;
      }
      _index = index;
      setState(() => _loading = false);
      await _prepareSources(force: false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = context.l10n.format('无法打开搜索索引：{error}', {'error': error});
        });
      }
    }
  }

  void _status(
    String id,
    String message, [
    Map<String, Object?> arguments = const {},
  ]) {
    if (mounted) {
      setState(
        () => _states[id] = AppLocalizations.of(
          context,
        ).format(message, arguments),
      );
    }
  }

  Future<void> _prepareSources({required bool force}) async {
    final index = _index;
    if (index == null || _indexing) return;
    setState(() {
      _indexing = true;
      _error = null;
    });
    try {
      final app = context.read<AppState>();
      final config = app.configStore.current;
      final mountedIds = config.mountedProfileIds.toSet();
      final roots = config.localRoots.where((root) => root.enabled).toList();
      final profiles = config.profiles
          .where((profile) => mountedIds.contains(profile.profileId))
          .toList();
      final sourceIds = {...roots.map((root) => root.sourceId), ...mountedIds};
      _sourceSignature = (sourceIds.toList()..sort()).join('|');
      _serverProfiles.removeWhere((id, _) => !sourceIds.contains(id));
      setState(() {
        _states.removeWhere((id, _) => !sourceIds.contains(id));
        _results = _results
            .where((result) => sourceIds.contains(result.sourceId))
            .toList();
      });
      for (final id in [
        ...roots.map((root) => root.sourceId),
        ...profiles.map((profile) => profile.profileId),
      ]) {
        _status(id, '等待建立索引');
      }
      await index.retainSources(sourceIds);
      for (final root in roots) {
        await _prepareLocal(app, root, force: force);
      }
      for (final profile in profiles) {
        await _prepareNetwork(app, profile, force: force);
      }
      _scheduleSearch(_controller.text);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = context.l10n.format('无法打开搜索索引：{error}', {
            'error': error,
          }),
        );
      }
    } finally {
      if (mounted) setState(() => _indexing = false);
    }
  }

  Future<void> _prepareLocal(
    AppState app,
    LocalRootConfig root, {
    required bool force,
  }) async {
    final index = _index!;
    final previous = await index.status(root.sourceId);
    if (!force && previous != null) {
      _status(root.sourceId, '已索引 {count} 项 · {time}', {
        'count': previous.entryCount,
        'time': previous.builtAt.toLocal(),
      });
      return;
    }
    final source = app.localMediaSource(root);
    try {
      _status(root.sourceId, '正在建立索引…');
      await index.indexSource(
        sourceId: root.sourceId,
        list: (path) => source.fetchDirectory(path, forceRefresh: true),
        shouldDescend: (entry) async =>
            entry is! LocalMediaEntry ||
            await FileSystemEntity.type(
                  entry.absolutePath,
                  followLinks: false,
                ) !=
                FileSystemEntityType.link,
        onProgress: (dirs, entries) => _status(
          root.sourceId,
          '已读取 {dirs} 个目录 · {entries} 项',
          {'dirs': dirs, 'entries': entries},
        ),
      );
      final status = await index.status(root.sourceId);
      _status(root.sourceId, '已索引 {count} 项', {'count': status!.entryCount});
    } catch (error) {
      _status(
        root.sourceId,
        previous == null ? '索引失败：{error} · 尚无完整结果' : '索引失败：{error} · 保留旧索引',
        {'error': error},
      );
    }
  }

  Future<void> _prepareNetwork(
    AppState app,
    ServerProfile profile, {
    required bool force,
    bool preferClient = false,
  }) async {
    final id = profile.profileId;
    try {
      final capabilities = preferClient
          ? null
          : await app.getOpenListCapabilities(profile: profile);
      if (capabilities?.indexSearch == OpenListCapabilitySupport.supported) {
        _serverProfiles[id] = profile;
        _status(id, '使用 OpenList/AList 服务端索引');
        return;
      }
    } catch (_) {
      // 普通 WebDAV 与未提供索引 API 的服务器使用客户端目录索引。
    }
    _serverProfiles.remove(id);
    final index = _index!;
    final previous = await index.status(id);
    if (!force && previous != null) {
      _status(id, '已索引 {count} 项 · {time}', {
        'count': previous.entryCount,
        'time': previous.builtAt.toLocal(),
      });
      return;
    }
    try {
      var service = app.mountedService(id);
      if (service == null) {
        await app.mountProfile(id);
        service = app.mountedService(id);
      }
      if (service == null) throw StateError('网络来源未连接');
      _status(id, '正在建立索引…');
      await index.indexSource(
        sourceId: id,
        list: (path) => service!.refreshDirectory(path),
        onProgress: (dirs, entries) => _status(
          id,
          '已读取 {dirs} 个目录 · {entries} 项',
          {'dirs': dirs, 'entries': entries},
        ),
      );
      final status = await index.status(id);
      _status(id, '已索引 {count} 项', {'count': status!.entryCount});
    } catch (error) {
      _status(
        id,
        previous == null ? '索引失败：{error} · 尚无完整结果' : '索引失败：{error} · 保留旧索引',
        {'error': error},
      );
    }
  }

  void _scheduleSearch(String query) {
    _debounce?.cancel();
    final generation = ++_searchGeneration;
    if (query.trim().isEmpty) {
      setState(() {
        _results = const [];
        _truncated = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_search(query, generation));
    });
  }

  Future<void> _search(String query, int generation) async {
    final index = _index;
    if (index == null) return;
    final app = context.read<AppState>();
    try {
      final results = <GlobalSearchResult>[
        ...await index.search(query, limit: 201),
      ];
      if (query.trim().length >= 2) {
        for (final entry in _serverProfiles.entries.toList()) {
          try {
            final hits = await app.searchOpenListIndexForProfile(
              entry.value,
              query,
            );
            results.addAll(
              hits.map(
                (hit) => GlobalSearchResult(
                  sourceId: entry.key,
                  parentPath: hit.parent,
                  name: hit.name,
                  isDirectory: hit.isDirectory,
                ),
              ),
            );
          } catch (error) {
            _status(entry.key, '服务端索引搜索失败：{error}', {'error': error});
            await _prepareNetwork(
              app,
              entry.value,
              force: false,
              preferClient: true,
            );
            results.addAll(
              await index.search(query, sourceId: entry.key, limit: 201),
            );
          }
        }
      }
      if (mounted && generation == _searchGeneration) {
        results.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
        setState(() {
          _truncated = results.length > 200;
          _results = results.take(200).toList();
        });
      }
    } catch (error) {
      if (mounted && generation == _searchGeneration) {
        setState(
          () =>
              _error = context.l10n.format('搜索索引失败：{error}', {'error': error}),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final config = app.configStore.current;
    final names = {
      for (final root in app.localRoots) root.sourceId: root.displayName,
      for (final profile in config.profiles) profile.profileId: profile.name,
    };
    final sourceIds = {
      ...app.localRoots
          .where((root) => root.enabled)
          .map((root) => root.sourceId),
      ...config.mountedProfileIds,
    };
    final signature = (sourceIds.toList()..sort()).join('|');
    if (_index != null && !_indexing && signature != _sourceSignature) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_prepareSources(force: false));
      });
    }
    return Scaffold(
      appBar: AppBar(toolbarHeight: 48, title: const AppText('搜索文件和文件夹')),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('global-search-field'),
                        controller: _controller,
                        contextMenuBuilder: buildClipboardHistoryMenu,
                        onChanged: _scheduleSearch,
                        decoration: InputDecoration(
                          hintText: context.l10n.text('搜索文件和文件夹'),
                          prefixIcon: const Icon(SPIcons.search),
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('global-search-refresh'),
                      tooltip: context.l10n.text('刷新客户端索引'),
                      icon: const Icon(SPIcons.refresh),
                      onPressed: _index == null || _indexing
                          ? null
                          : () => _prepareSources(force: true),
                    ),
                  ],
                ),
              ),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null) AppText(_error!),
              if (_truncated) const AppText('仅显示前 200 条，请缩小搜索范围'),
              if (_states.isNotEmpty)
                ExpansionTile(
                  title: const AppText('各来源索引状态'),
                  children: [
                    for (final entry in _states.entries)
                      ListTile(
                        dense: true,
                        title: AppText(names[entry.key] ?? entry.key),
                        subtitle: AppText(entry.value),
                      ),
                  ],
                ),
              Expanded(
                child: _results.isEmpty
                    ? const SizedBox.expand()
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (context, index) {
                          final result = _results[index];
                          return ListTile(
                            key: ValueKey(
                              'search-${result.sourceId}-${result.path}',
                            ),
                            leading: Icon(
                              result.isDirectory
                                  ? SPIcons.folder
                                  : SPIcons.document,
                            ),
                            title: AppText(result.name),
                            subtitle: AppText(
                              '${names[result.sourceId] ?? result.sourceId} · '
                              '${result.parentPath.isEmpty ? '/' : result.parentPath}',
                            ),
                            onTap: () => widget.onOpenResult(result),
                          );
                        },
                      ),
              ),
            ],
          ),
          if (_results.isEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        SPIcons.search,
                        size: 36,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      AppText(
                        _controller.text.trim().isEmpty ? '暂未搜索内容' : '未找到匹配项',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
