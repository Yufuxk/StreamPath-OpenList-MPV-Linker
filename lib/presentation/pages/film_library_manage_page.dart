import '../widgets/sp_menu.dart';
import '../../data/local/film_catalog_store.dart';
import '../../domain/services/film_catalog_scanner.dart';
import '../widgets/film_directory_dialog.dart';
import '../widgets/directory_scroll_view.dart';
import '../widgets/settings_group_card.dart';
import '../widgets/settings_columns.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/film_catalog_item.dart';
import '../../data/models/media_source.dart';
import '../../domain/repositories/media_directory_source.dart';
import '../../domain/services/webdav_media_source_adapter.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/film_catalog_tasks.dart';
import '../widgets/sp_dialog.dart';
import '../widgets/sp_icons.dart';
import '../widgets/sp_notice.dart';
import '../widgets/film_artwork_picker.dart';
import '../widgets/film_section_settings.dart';
import '../widgets/film_transfer_dialog.dart';
import '../widgets/sp_controls.dart';

Future<void> showFilmRootEditor(
  BuildContext context,
  FilmCatalogController catalog, {
  FilmCatalogRoot? root,
}) async {
  final saved = await showGlassDialog<bool>(
    context: context,
    builder: (_) => _AddFilmRootDialog(catalog: catalog, root: root),
  );
  if (saved == true) await catalog.refresh();
}

class FilmLibraryManagePage extends StatefulWidget {
  const FilmLibraryManagePage({
    super.key,
    required this.catalog,
    this.embedded = false,
    this.directories = false,
  });
  final FilmCatalogController catalog;
  final bool embedded;
  final bool directories;
  @override
  State<FilmLibraryManagePage> createState() => _FilmLibraryManagePageState();
}

class _FilmLibraryManagePageState extends State<FilmLibraryManagePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.directories;

  final _token = TextEditingController();
  String _language = 'zh-CN';
  String _probeMode = 'playback';
  bool _hasToken = false;
  bool _scanEnabled = true, _spoilers = false;
  int _scanHours = 24;
  bool _saving = false;
  final _sourceSettings = <String, List<bool>>{};
  final _rootEnabled = <int, bool>{};
  @override
  void initState() {
    super.initState();
    _loadSettings(refreshCatalog: widget.catalog.roots.isEmpty);
  }

  Future<void> _loadSettings({bool refreshCatalog = true}) async {
    await widget.catalog.run(() async {
      if (widget.directories && refreshCatalog) await widget.catalog.refresh();
      final language = await widget.catalog.store.language();
      final token = await widget.catalog.tmdb.hasToken();
      final probeMode = await widget.catalog.store.probeMode();
      for (final root in await widget.catalog.store.roots()) {
        _rootEnabled[root.id] =
            await widget.catalog.store.preference('root_enabled:${root.id}') !=
            false;
        _sourceSettings[root.sourceId] = [
          await widget.catalog.store.preference(
                'local_metadata:${root.sourceId}',
              ) ==
              true,
          await widget.catalog.store.preference(
                'write_back:${root.sourceId}',
              ) ==
              true,
          await widget.catalog.store.preference('read_only:${root.sourceId}') ==
              true,
        ];
      }
      _scanEnabled =
          await widget.catalog.store.preference('scan_enabled') != false;
      _spoilers =
          await widget.catalog.store.preference('spoiler_protection') == true;
      _scanHours =
          (await widget.catalog.store.preference('scan_interval_hours')
              as int?) ??
          24;
      if (mounted) {
        setState(() {
          _language = language;
          _hasToken = token;
          _probeMode = probeMode;
        });
      }
    });
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _settingAction(
    Future<void> Function() action, {
    String successText = '操作完成',
  }) async {
    setState(() => _saving = true);
    final ok = await widget.catalog.run(action);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      await _loadSettings();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SPNotice(content: AppText(successText)));
      }
    }
  }

  Future<void> _addRoot() async {
    await showFilmRootEditor(context, widget.catalog);
  }

  Future<void> _scanMultiple() async {
    final selected = <int>{...widget.catalog.roots.map((r) => r.id)};
    var incremental = false;
    final start = await showGlassDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => SPDialog(
          title: const AppText('扫描多个来源'),
          content: SizedBox(
            width: 560,
            child: DirectoryScrollView(
              builder: (scrollController) => SingleChildScrollView(
                controller: scrollController,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final root in widget.catalog.roots)
                      CheckboxListTile(
                        title: Text(root.displayName),
                        subtitle: Text(root.path),
                        value: selected.contains(root.id),
                        onChanged: (value) => setDialogState(() {
                          if (value!) {
                            selected.add(root.id);
                          } else {
                            selected.remove(root.id);
                          }
                        }),
                      ),
                    SwitchListTile(
                      title: const AppText('增量扫描'),
                      value: incremental,
                      onChanged: (value) =>
                          setDialogState(() => incremental = value),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const AppText('取消'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: const AppText('开始扫描'),
            ),
          ],
        ),
      ),
    );
    if (start == true) {
      await widget.catalog.scanRoots(
        widget.catalog.roots.where((r) => selected.contains(r.id)).toList(),
        incremental: incremental,
      );
    }
  }

  Future<void> _remove(FilmCatalogRoot root) async {
    final confirm = await showGlassDialog<bool>(
      context: context,
      builder: (context) => SPDialog(
        title: const AppText('移除影视目录？'),
        content: AppText('只移除影视目录库中的记录，媒体文件保持原样'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const AppText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const AppText('移除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await widget.catalog.run(() => widget.catalog.store.removeRoot(root.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final c = widget.catalog;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final content = DirectoryScrollView(
          builder: (scrollController) => ListView(
            controller: scrollController,
            shrinkWrap: widget.embedded && !widget.directories,
            physics: widget.embedded && !widget.directories
                ? const NeverScrollableScrollPhysics()
                : null,
            padding: EdgeInsets.all(
              widget.embedded && !widget.directories ? 0 : 24,
            ),
            children: [
              if (widget.directories)
                SettingsGroupCard(
                  icon: SPIcons.folderOpen,
                  title: '管理影视目录',
                  description: '递归视频、ISO 与 BDMV，包含特别篇；播放沿用已有播放器',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      const AppText('温和扫描：逐目录串行读取名称，网盘请求间隔至少一秒，不探测媒体内容'),
                      const SizedBox(height: 8),
                      const AppText('增量扫描收录新增和重新出现的文件；增量刮削只处理未匹配作品的剧集'),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: _addRoot,
                            icon: const Icon(SPIcons.add),
                            label: const AppText('添加影视目录'),
                          ),
                          OutlinedButton.icon(
                            onPressed: c.busy || c.roots.isEmpty
                                ? null
                                : _scanMultiple,
                            icon: const Icon(SPIcons.refresh),
                            label: const AppText('扫描多个来源'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      for (final root in c.roots)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        root.displayName,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                    ),
                                    Tooltip(
                                      message: context.l10n.text('启用影视库'),
                                      child: Switch(
                                        key: ValueKey(
                                          'film-root-enabled-${root.id}',
                                        ),
                                        value: root.enabled,
                                        onChanged: _saving
                                            ? null
                                            : (value) => _settingAction(
                                                () => c.store.setRootEnabled(
                                                  root.id,
                                                  value,
                                                ),
                                              ),
                                      ),
                                    ),
                                  ],
                                ),
                                SelectableText(
                                  contextMenuBuilder: buildSPTextSelectionMenu,
                                  root.path.isEmpty ? '/' : root.path,
                                ),
                                AppText(
                                  root.type == FilmMediaType.movie
                                      ? '电影'
                                      : '剧集',
                                ),
                                AppText(switch (root.status) {
                                  'running' => '正在扫描…',
                                  'completed' => '扫描完成',
                                  'cancelled' => '扫描已取消',
                                  'failed' => '扫描失败',
                                  _ => '尚未扫描',
                                }),
                                if (root.lastSuccessAt != null)
                                  Text(
                                    context.l10n.format('上次成功：{time}', {
                                      'time':
                                          DateTime.fromMillisecondsSinceEpoch(
                                            root.lastSuccessAt!,
                                          ).toLocal(),
                                    }),
                                  ),
                                if (root.lastError != null)
                                  AppText(
                                    filmCatalogErrorText(root.lastError!),
                                  ),
                                CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const AppText('参与定时扫描'),
                                  value: _rootEnabled[root.id] ?? true,
                                  onChanged: _saving
                                      ? null
                                      : (value) => _settingAction(
                                          () => c.store.setPreference(
                                            'root_enabled:${root.id}',
                                            value,
                                          ),
                                        ),
                                ),
                                if (root.sourceKind == MediaSourceKind.local ||
                                    root.sourceKind == MediaSourceKind.webdav)
                                  for (final setting in [
                                    (0, 'local_metadata', '本地元数据模式'),
                                    (1, 'write_back', '允许写回缺少的 NFO 和图片'),
                                    (2, 'read_only', '只读来源'),
                                  ])
                                    CheckboxListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: AppText(setting.$3),
                                      value:
                                          _sourceSettings[root
                                              .sourceId]?[setting.$1] ??
                                          false,
                                      onChanged:
                                          _saving ||
                                              (setting.$1 == 1 &&
                                                  (_sourceSettings[root
                                                          .sourceId]?[2] ??
                                                      false))
                                          ? null
                                          : (value) => _settingAction(
                                              () => c.store.setPreference(
                                                '${setting.$2}:${root.sourceId}',
                                                value,
                                              ),
                                            ),
                                    ),
                                Wrap(
                                  spacing: 12,
                                  children: [
                                    TextButton.icon(
                                      onPressed: c.busy || c.scraping
                                          ? null
                                          : () => showFilmRootEditor(
                                              context,
                                              c,
                                              root: root,
                                            ),
                                      icon: const Icon(SPIcons.edit),
                                      label: const AppText('编辑影视目录'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () => showFilmArtworkPicker(
                                        context,
                                        c,
                                        rootId: root.id,
                                      ),
                                      icon: const Icon(SPIcons.video),
                                      label: const AppText('修改图片'),
                                    ),
                                    TextButton.icon(
                                      onPressed: c.busy
                                          ? null
                                          : () => c.scan(root),
                                      icon: const Icon(SPIcons.refresh),
                                      label: const AppText('手动扫描'),
                                    ),
                                    TextButton.icon(
                                      onPressed: c.busy
                                          ? null
                                          : () async {
                                              final path =
                                                  await showGlassDialog<String>(
                                                    context: context,
                                                    builder: (_) =>
                                                        FilmDirectoryDialog(
                                                          source: c.sourceFor(
                                                            root,
                                                          ),
                                                          initialPath:
                                                              root.path,
                                                          boundaryPath:
                                                              root.path,
                                                        ),
                                                  );
                                              if (path != null && mounted) {
                                                await c.scan(
                                                  root,
                                                  scope: FilmScanScope(
                                                    root.id,
                                                    path,
                                                  ),
                                                );
                                              }
                                            },
                                      icon: const Icon(SPIcons.folder),
                                      label: const AppText('指定扫描'),
                                    ),
                                    TextButton.icon(
                                      onPressed: c.busy
                                          ? null
                                          : () =>
                                                c.scan(root, incremental: true),
                                      icon: const Icon(SPIcons.add),
                                      label: const AppText('增量扫描'),
                                    ),
                                    TextButton.icon(
                                      onPressed: c.isScrapingRoot(root.id)
                                          ? null
                                          : () => c.scrape(root),
                                      icon: const Icon(SPIcons.refresh),
                                      label: const AppText('刮削元数据'),
                                    ),
                                    TextButton.icon(
                                      onPressed:
                                          root.type != FilmMediaType.tv ||
                                              c.isScrapingRoot(root.id)
                                          ? null
                                          : () => c.scrape(
                                              root,
                                              incremental: true,
                                            ),
                                      icon: const Icon(SPIcons.refresh),
                                      label: const AppText('增量刮削'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () => _remove(root),
                                      icon: const Icon(SPIcons.delete),
                                      label: const AppText('移除'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      FilmCatalogTasks(catalog: c, panel: true),
                    ],
                  ),
                ),
              if (!widget.directories) ...[
                FilmCatalogTasks(catalog: c, panel: true),
                const SizedBox(height: 16),
                SettingsColumns(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SettingsGroupCard(
                          icon: SPIcons.apps,
                          title: '首页栏目',
                          description: '选择显示的分类，拖动调整从上到下的顺序',
                          child: FilmSectionSettings(catalog: c),
                        ),
                        const SizedBox(height: 16),
                        SettingsGroupCard(
                          icon: SPIcons.settings,
                          title: 'TMDB 元数据设置',
                          description: '',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 12),
                              AppText(
                                _hasToken
                                    ? '已保存 TMDB 凭据'
                                    : '未保存 TMDB 凭据；仍可建库和播放文件',
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _token,
                                obscureText: true,
                                enableSuggestions: false,
                                autocorrect: false,
                                onChanged: (_) => setState(() {}),
                                decoration: const InputDecoration(
                                  label: AppText('TMDB Read Access Token'),
                                  helper: AppText('保存后输入框会清空；验证使用已保存的凭据'),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 12,
                                runSpacing: 8,
                                children: [
                                  FilledButton(
                                    onPressed:
                                        _saving || _token.text.trim().isEmpty
                                        ? null
                                        : () => _settingAction(() async {
                                            await c.tmdb.saveToken(_token.text);
                                            _token.clear();
                                          }, successText: '已保存 TMDB 凭据'),
                                    child: const AppText('保存凭据'),
                                  ),
                                  TextButton(
                                    onPressed: _saving || !_hasToken
                                        ? null
                                        : () => _settingAction(
                                            c.tmdb.verify,
                                            successText: 'TMDB 凭据验证通过',
                                          ),
                                    child: const AppText('验证凭据'),
                                  ),
                                  TextButton(
                                    onPressed: _saving || !_hasToken
                                        ? null
                                        : () =>
                                              _settingAction(c.tmdb.clearToken),
                                    child: const AppText('清除凭据'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              SizedBox(
                                width: 260,
                                child: SPDropdownButtonFormField<String>(
                                  dropdownColor: AppTheme.dropdownMenuColor(
                                    Theme.of(context),
                                  ),
                                  borderRadius: AppTheme.dropdownBorderRadius,
                                  isExpanded: true,
                                  key: ValueKey(_language),
                                  initialValue: _language,
                                  decoration: const InputDecoration(
                                    label: AppText('元数据语言'),
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'zh-CN',
                                      child: Text('简体中文'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'zh-TW',
                                      child: Text('繁體中文'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'ja-JP',
                                      child: Text('日本語'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'en-US',
                                      child: Text('English'),
                                    ),
                                  ],
                                  onChanged: _saving
                                      ? null
                                      : (value) => _settingAction(
                                          () => c.store.setLanguage(value!),
                                        ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              const AppText('语言更改用于后续请求；已有作品可在详情页手动刷新'),
                              const SizedBox(height: 16),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                  onPressed: _saving
                                      ? null
                                      : () => _settingAction(c.images.clear),
                                  child: const AppText('清理影视图片缓存'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SettingsGroupCard(
                          icon: SPIcons.video,
                          title: '影视库背景',
                          description: '默认背景跟随软件界面样式，也可选择本地图片或已缓存封面',
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () =>
                                  showFilmArtworkPicker(context, c),
                              child: const AppText('设置影视库背景'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SettingsGroupCard(
                          icon: SPIcons.settings,
                          title: '影视库偏好',
                          description: '',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 12),
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  final wide =
                                      constraints.maxWidth >=
                                      560 *
                                          MediaQuery.textScalerOf(
                                            context,
                                          ).scale(14) /
                                          14;
                                  return Wrap(
                                    spacing: 16,
                                    runSpacing: 12,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      SizedBox(
                                        width: wide
                                            ? constraints.maxWidth - 236
                                            : constraints.maxWidth,
                                        child: SPToggleTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: const AppText('自动扫描'),
                                          value: _scanEnabled,
                                          onChanged: (value) => _settingAction(
                                            () => c.store.setPreference(
                                              'scan_enabled',
                                              value,
                                            ),
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: wide
                                            ? 220
                                            : constraints.maxWidth,
                                        child: SPDropdownButtonFormField<int>(
                                          isExpanded: true,
                                          initialValue: _scanHours,
                                          key: ValueKey(_scanHours),
                                          decoration: InputDecoration(
                                            labelText: context.l10n.text(
                                              '扫描间隔',
                                            ),
                                          ),
                                          items: [
                                            for (final hours in [
                                              6,
                                              12,
                                              24,
                                              48,
                                              168,
                                            ])
                                              DropdownMenuItem(
                                                value: hours,
                                                child: Text(
                                                  context.l10n.format(
                                                    '{hours} 小时',
                                                    {'hours': hours},
                                                  ),
                                                ),
                                              ),
                                          ],
                                          onChanged: (value) => _settingAction(
                                            () => c.store.setPreference(
                                              'scan_interval_hours',
                                              value,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: 12),
                              SPToggleTile(
                                contentPadding: EdgeInsets.zero,
                                title: const AppText('防剧透'),
                                value: _spoilers,
                                onChanged: (value) => _settingAction(
                                  () => c.store.setPreference(
                                    'spoiler_protection',
                                    value,
                                  ),
                                ),
                              ),
                              const Divider(height: 24),
                              Wrap(
                                spacing: 12,
                                runSpacing: 8,
                                children: [
                                  TextButton.icon(
                                    icon: const Icon(SPIcons.download),
                                    onPressed: () =>
                                        showFilmTransferDialog(context),
                                    label: const AppText('导出影视库'),
                                  ),
                                  TextButton.icon(
                                    icon: const Icon(SPIcons.restore),
                                    onPressed: () => showFilmTransferDialog(
                                      context,
                                      importing: true,
                                    ),
                                    label: const AppText('导入影视库'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        SettingsGroupCard(
                          icon: SPIcons.diagnostic,
                          title: '视频信息探测',
                          description: '',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 12),
                              SPDropdownButtonFormField<String>(
                                key: ValueKey(_probeMode),
                                borderRadius: AppTheme.dropdownBorderRadius,
                                isExpanded: true,
                                initialValue: _probeMode,
                                dropdownColor: AppTheme.dropdownMenuColor(
                                  Theme.of(context),
                                ),
                                decoration: const InputDecoration(
                                  label: AppText('探测模式'),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'playback',
                                    child: AppText('播放时探测（默认）'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'full',
                                    child: AppText('媒体库完整探测'),
                                  ),
                                ],
                                onChanged: _saving
                                    ? null
                                    : (value) => _settingAction(
                                        () =>
                                            c.mediaProbe?.setMode(value!) ??
                                            c.store.setProbeMode(value!),
                                      ),
                              ),
                              const SizedBox(height: 8),
                              const AppText(
                                '警告：完整探测会读取所有媒体的部分内容，可能唤醒硬盘、消耗流量或触发服务器限流。任务仅在无播放时低频运行，开始播放会取消当前探测；STRM 在播放时获取参数。',
                              ),
                              if (c.mediaProbe != null) ...[
                                const SizedBox(height: 8),
                                if (c.mediaProbe!.busy)
                                  const LinearProgressIndicator(),
                                if (_probeMode == 'full')
                                  AppText(
                                    c.mediaProbe!.pausedForPlayback
                                        ? '探测已暂停，播放优先'
                                        : '后台低频探测',
                                  ),
                                if (c.mediaProbe!.error != null)
                                  AppText(
                                    filmCatalogErrorText(c.mediaProbe!.error!),
                                  ),
                                TextButton(
                                  onPressed: c.mediaProbe!.busy
                                      ? null
                                      : () => _settingAction(
                                          c.mediaProbe!.retryFailed,
                                        ),
                                  child: const AppText('重试失败或不完整的探测'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (c.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: AppText(
                      filmCatalogErrorText(c.error!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const Divider(height: 40),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Image.asset('assets/tmdb_logo.png', width: 120),
                ),
                const SizedBox(height: 12),
                const Text(
                  'This product uses the TMDB API but is not endorsed or certified by TMDB.',
                ),
              ],
            ],
          ),
        );
        return widget.embedded
            ? content
            : Scaffold(
                appBar: AppBar(
                  toolbarHeight: 48,
                  title: AppText(widget.directories ? '管理影视目录' : '影视库'),
                ),
                body: content,
              );
      },
    );
  }
}

class _AddFilmRootDialog extends StatefulWidget {
  const _AddFilmRootDialog({required this.catalog, this.root});
  final FilmCatalogController catalog;
  final FilmCatalogRoot? root;
  @override
  State<_AddFilmRootDialog> createState() => _AddFilmRootDialogState();
}

class _AddFilmRootDialogState extends State<_AddFilmRootDialog> {
  MediaSourceDescriptor? _source;
  String? _path;
  FilmMediaType _type = FilmMediaType.movie;
  final _name = TextEditingController();
  String? _error;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    if (widget.root case final root?) {
      _source = MediaSourceDescriptor(
        sourceId: root.sourceId,
        kind: root.sourceKind,
        displayName: root.displayName,
      );
      _path = root.path;
      _type = root.type;
      _name.text = root.displayName;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  MediaDirectorySource _directorySource() {
    final app = context.read<AppState>();
    if (_source!.kind.isNativeStorage) {
      return app.directorySource(_source!.sourceId);
    }
    if (_source!.kind == MediaSourceKind.local) {
      final root = app.localRoots
          .where((r) => r.sourceId == _source!.sourceId && r.enabled)
          .firstOrNull;
      if (root != null) return app.localMediaSource(root);
    } else {
      final service = app.mountedService(_source!.sourceId);
      if (service != null) return WebDavMediaSourceAdapter(service);
    }
    throw const FilmCatalogException('sourceUnavailable');
  }

  Future<void> _choose() async {
    MediaDirectorySource? source;
    final ok = await widget.catalog.run(() async {
      if (_source!.kind.isNativeStorage) {
        await context.read<AppState>().mountMediaConnection(_source!.sourceId);
      }
      source = _directorySource();
    });
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = widget.catalog.error);
      return;
    }
    final path = await showGlassDialog<String>(
      context: context,
      builder: (_) => FilmDirectoryDialog(source: source!),
    );
    if (path != null && mounted) setState(() => _path = path);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await widget.catalog.run(() async {
      final name = _name.text.trim().isEmpty
          ? '${_source!.displayName} · ${_path!.isEmpty ? '/' : _path!}'
          : _name.text.trim();
      if (widget.root case final root?) {
        await widget.catalog.store.updateRoot(
          root,
          sourceId: _source!.sourceId,
          kind: _source!.kind,
          path: _path!,
          type: _type,
          name: name,
        );
      } else {
        await widget.catalog.store.addRoot(
          sourceId: _source!.sourceId,
          kind: _source!.kind,
          path: _path!,
          type: _type,
          name: name,
        );
      }
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = widget.catalog.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final sources = <MediaSourceDescriptor>[
      for (final connection in app.mediaConnections.where(
        (row) => row.enabled && row.kind.isNativeStorage,
      ))
        MediaSourceDescriptor(
          sourceId: connection.id,
          kind: connection.kind,
          displayName: connection.name,
        ),
      for (final root in app.localRoots.where((r) => r.enabled))
        MediaSourceDescriptor(
          sourceId: root.sourceId,
          kind: MediaSourceKind.local,
          displayName: root.displayName,
        ),
      for (final profile in app.configStore.current.profiles.where(
        (p) => app.configStore.current.mountedProfileIds.contains(p.profileId),
      ))
        MediaSourceDescriptor(
          sourceId: profile.profileId,
          kind: MediaSourceKind.webdav,
          displayName: profile.name,
        ),
    ];
    if (_source != null &&
        !sources.any((s) => s.sourceId == _source!.sourceId)) {
      sources.add(_source!);
    }
    return SPDialog(
      title: AppText(widget.root == null ? '添加影视目录' : '编辑影视目录'),
      content: SizedBox(
        width: 560,
        child: DirectoryScrollView(
          builder: (scrollController) => SingleChildScrollView(
            controller: scrollController,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SPDropdownButtonFormField<String>(
                  initialValue: _source?.sourceId,
                  dropdownColor: AppTheme.dropdownMenuColor(Theme.of(context)),
                  borderRadius: AppTheme.dropdownBorderRadius,
                  isExpanded: true,
                  decoration: const InputDecoration(label: AppText('已有来源')),
                  items: [
                    for (final source in sources)
                      DropdownMenuItem(
                        value: source.sourceId,
                        child: Text(source.displayName),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() {
                          _source = sources.firstWhere(
                            (s) => s.sourceId == value,
                          );
                          _path = null;
                        }),
                ),
                const SizedBox(height: 16),
                SPDropdownButtonFormField<FilmMediaType>(
                  dropdownColor: AppTheme.dropdownMenuColor(Theme.of(context)),
                  borderRadius: AppTheme.dropdownBorderRadius,
                  isExpanded: true,
                  initialValue: _type,
                  decoration: const InputDecoration(label: AppText('作品类型')),
                  items: const [
                    DropdownMenuItem(
                      value: FilmMediaType.movie,
                      child: AppText('电影'),
                    ),
                    DropdownMenuItem(
                      value: FilmMediaType.tv,
                      child: AppText('剧集'),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _type = value!),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(label: AppText('显示名称（可选）')),
                ),
                if (widget.root != null)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: AppText(
                      '更改来源、目录或类型会重建该目录的库记录与人工匹配；保存前自动备份，保存后请重新扫描',
                    ),
                  ),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: _source == null || _saving ? null : _choose,
                  icon: const Icon(SPIcons.folder),
                  label: const AppText('选择来源内目录'),
                ),
                if (_path != null)
                  SelectableText(
                    contextMenuBuilder: buildSPTextSelectionMenu,
                    _path!.isEmpty ? '/' : _path!,
                  ),
                if (_error != null) AppText(filmCatalogErrorText(_error!)),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const AppText('取消'),
        ),
        FilledButton(
          onPressed: _source == null || _path == null || _saving ? null : _save,
          child: AppText(widget.root == null ? '添加' : '保存'),
        ),
      ],
    );
  }
}
