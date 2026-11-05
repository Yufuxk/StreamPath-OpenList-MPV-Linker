import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../data/models/player_config.dart';
import '../../data/models/playback_media_info.dart';
import '../../presentation/localization/app_localizations.dart';
import '../../presentation/localization/app_text.dart';
import '../../presentation/widgets/clipboard_history_menu.dart';
import '../../presentation/widgets/directory_scroll_view.dart';
import '../../presentation/widgets/film_segmented_control.dart';
import '../../presentation/widgets/glass_dialog.dart';
import '../../presentation/widgets/settings_group_card.dart';
import '../../presentation/widgets/section_switcher.dart';
import '../../presentation/widgets/sp_back_icon.dart';
import '../../presentation/widgets/sp_controls.dart';
import '../../presentation/widgets/sp_dialog.dart';
import '../../presentation/widgets/sp_icons.dart';
import '../../presentation/widgets/sp_menu.dart';
import '../../presentation/widgets/sp_notice.dart';
import '../../presentation/widgets/sp_reorderable.dart';
import 'mpv_document.dart';
import 'mpv_file_store.dart';
import 'mpv_installation.dart';
import 'mpv_script_schema.dart';

enum _Tab { overview, options, input, scripts, shaders, history }

const _labels = ['概览', 'MPV 参数', '快捷键', '本地插件', '着色器', '更改记录'];

class MpvManagerPage extends StatefulWidget {
  const MpvManagerPage({
    super.key,
    required this.player,
    required this.store,
    this.initialInstallation,
  });
  final PlayerConfig player;
  final MpvFileStore store;
  final MpvInstallationContext? initialInstallation;
  @override
  State<MpvManagerPage> createState() => _MpvManagerPageState();
}

class _MpvManagerPageState extends State<MpvManagerPage> {
  _Tab _tab = _Tab.overview;
  _Tab _contentTab = _Tab.overview;
  MpvInstallationContext? _installation;
  MpvDocumentSnapshot? _document;
  MpvCapabilities? _capabilities;
  MpvCapabilityProbe? _probe;
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _watchDebounce;
  final _search = TextEditingController();
  String? _error, _probeError, _browseRoot;
  bool _loading = true, _busy = false, _external = false;
  int _generation = 0, _block = 0;
  int _documentGeneration = 0;
  int _mediaContext = 0;
  String _category = '全部参数';
  String _commandCategory = '全部命令';
  List<MpvHistoryEntry> _history = [];

  @override
  void initState() {
    super.initState();
    _installation = widget.initialInstallation;
    unawaited(_scan());
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_watch?.cancel());
    unawaited(_probe?.close());
    _watchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _capabilities = null;
      _probeError = null;
    });
    await _probe?.close();
    try {
      var installation =
          widget.initialInstallation ??
          await discoverMpv(
            widget.player,
            browseRoot: _browseRoot,
            mediaInfo: switch (_mediaContext) {
              1 => const PlaybackMediaInfo(isSeries: false, isAnime: false),
              2 => const PlaybackMediaInfo(isSeries: true, isAnime: false),
              3 => const PlaybackMediaInfo(isSeries: false, isAnime: true),
              4 => const PlaybackMediaInfo(isSeries: true, isAnime: true),
              _ => null,
            },
          );
      final associations = await widget.store.associations();
      final files = [...installation.files];
      final scripts = installation.scripts.map((script) {
        final config =
            associations[mpvScriptAssociationKey(script.path)] ??
            script.configPath;
        if (config != null &&
            !files.any((file) => p.equals(file.path, config))) {
          files.add(
            MpvManagedFile(
              config,
              MpvDocumentKind.scriptOptions,
              'script-opts',
              exists: File(config).existsSync(),
            ),
          );
        }
        return MpvLocalScript(
          script.path,
          script.source,
          script.automatic,
          script.explicit,
          config,
          schema: script.schema,
        );
      }).toList();
      installation = MpvInstallationContext(
        installation.executable,
        installation.roots,
        files,
        scripts,
        installation.shaders,
        installation.configDisabled,
        installation.diagnostics,
      );
      final history = await widget.store.history();
      if (!mounted || generation != _generation) return;
      setState(() {
        _installation = installation;
        _history = history;
        _loading = false;
      });
      final previous = _document?.path;
      final tabFiles = _tabFiles;
      if (tabFiles.isNotEmpty) {
        await _open(
          tabFiles.firstWhere(
            (f) => f.path == previous,
            orElse: () => _preferredFile(tabFiles),
          ),
        );
      }
      if (!mounted || generation != _generation) return;
      if (widget.initialInstallation == null) {
        final probe = MpvCapabilityProbe();
        _probe = probe;
        final keys = <String>{
          'hwdec',
          'vo',
          'ao',
          'fullscreen',
          'volume',
          'sub-font-size',
          'sub-scale',
          'video-sync',
          'deband',
        };
        for (final file in installation.files.where(
          (f) => f.kind == MpvDocumentKind.options,
        )) {
          final doc = await widget.store.load(file.path, file.kind);
          if (!mounted || generation != _generation) return;
          keys.addAll(doc.entries.map((e) => e.key));
        }
        try {
          final capabilities = await probe.read(installation.executable, keys);
          if (mounted && generation == _generation) {
            setState(() {
              _capabilities = capabilities;
              _probeError = null;
            });
          }
        } on Object catch (error) {
          if (mounted && generation == _generation) {
            setState(() => _probeError = _message(error));
          }
        }
      }
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = _message(error);
        });
      }
    }
  }

  List<MpvManagedFile> get _tabFiles => switch (_tab) {
    _Tab.options =>
      _installation?.files
              .where((f) => f.kind == MpvDocumentKind.options)
              .toList() ??
          [],
    _Tab.input =>
      _installation?.files
              .where((f) => f.kind == MpvDocumentKind.input)
              .toList() ??
          [],
    _Tab.scripts =>
      _installation?.files
              .where((f) => f.kind == MpvDocumentKind.scriptOptions)
              .toList() ??
          [],
    _Tab.shaders =>
      _installation?.files
              .where((f) => f.kind == MpvDocumentKind.options)
              .toList() ??
          [],
    _ => [],
  };

  Future<void> _open(MpvManagedFile file) async {
    final generation = ++_documentGeneration;
    await _watch?.cancel();
    _watch = null;
    final document = await widget.store.load(file.path, file.kind);
    if (!mounted || generation != _documentGeneration) return;
    setState(() {
      _document = document;
      _block = 0;
      _commandCategory = '全部命令';
      _external = false;
    });
    final parent = File(document.path).parent;
    if (parent.existsSync()) {
      _watch = parent.watch().listen(
        (_) {
          _watchDebounce?.cancel();
          _watchDebounce = Timer(
            const Duration(milliseconds: 180),
            () => unawaited(_checkExternal()),
          );
        },
        onError: (Object error) {
          if (mounted) _notice(_message(error));
        },
      );
    }
  }

  Future<void> _checkExternal() async {
    final document = _document;
    if (!mounted || document == null || _busy) return;
    try {
      final fresh = await widget.store.load(document.path, document.kind);
      if (mounted &&
          identical(document, _document) &&
          (fresh.revision != document.revision ||
              fresh.exists != document.exists)) {
        setState(() => _external = true);
      }
    } on FileSystemException catch (error) {
      if (mounted) _notice(_message(error));
    }
  }

  String _message(Object error) {
    if (error is Error) Error.throwWithStackTrace(error, StackTrace.current);
    final code = error is MpvManagerException ? error.code : 'io';
    return switch (code) {
      'busy' => '记录操作尚未完成，请稍后再试。',
      'conflict' => '文件已在外部修改，请重新加载后再编辑。',
      'encoding' => '文件不是有效 UTF-8，已保留原文件并设为只读。',
      'executable' => '无法解析 MPV，请先保存有效的播放器路径。',
      'probe' => '无法读取 MPV 参数信息，可继续使用文本编辑。',
      'singleLine' || 'commandComment' || 'key' => '输入格式无效，请检查参数名、命令和换行。',
      'destinationExists' => '目标文件已存在，未覆盖任何文件。',
      'scriptLink' => '链接脚本请在加载声明中管理，不能直接重命名。',
      'archiveFailed' => '文件已写入，但历史归档失败；请检查同目录的恢复文件。',
      'replaceFailed' => '文件替换失败，请检查权限、占用及同目录的恢复文件。',
      _ => '操作失败，请检查文件是否存在、目录权限和磁盘空间。',
    };
  }

  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SPNotice(content: AppText(message)));
    }
  }

  Future<void> _commit(
    MpvDocumentSnapshot document,
    List<MpvTextEdit> edits,
  ) async {
    if (edits.isEmpty) return;
    if (_busy) throw const MpvManagerException('busy');
    setState(() => _busy = true);
    try {
      final fresh = await widget.store.commit(document, edits);
      final history = await widget.store.history();
      if (!mounted) return;
      setState(() {
        if (_document?.path == document.path) {
          _document = fresh;
          if (fresh.kind == MpvDocumentKind.input &&
              !fresh.entries.any(
                (line) => _inputCategory(line) == _commandCategory,
              )) {
            _commandCategory = '全部命令';
          }
          _external = false;
        }
        _history = history;
      });
      _notice('已保存，重新启动播放器后生效。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (mounted) _notice(_message(error));
    }
  }

  void _select(_Tab tab) {
    if (_tab == tab) return;
    _documentGeneration++;
    setState(() => _tab = tab);
  }

  void _activate(_Tab tab) {
    if (!mounted || tab != _tab) return;
    setState(() {
      _contentTab = tab;
      _document = null;
      _search.clear();
    });
    final files = _tabFiles;
    if (files.isNotEmpty) {
      unawaited(_perform(() => _open(_preferredFile(files))));
    }
  }

  MpvManagedFile _preferredFile(List<MpvManagedFile> files) {
    final main = files.where((file) => file.origin == 'mpv.conf');
    return main.isEmpty ? files.first : main.last;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          tooltip: l10n.text('返回'),
          icon: const SPBackIcon(),
        ),
        title: const AppText('MPV 本地管理器'),
        actions: [
          TextButton(
            onPressed: _loading || _busy || _tab != _contentTab ? null : _scan,
            child: const AppText('重新扫描'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: LayoutBuilder(
                  builder: (context, constraints) => SizedBox(
                    height: MediaQuery.textScalerOf(context).scale(14) + 42,
                    child: DirectoryScrollView(
                      scrollDirection: Axis.horizontal,
                      builder: (controller) => SingleChildScrollView(
                        controller: controller,
                        scrollDirection: Axis.horizontal,
                        child: Align(
                          alignment: Alignment.center,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minWidth: constraints.maxWidth,
                            ),
                            child: FilmSegmentedControl<_Tab>(
                              segments: [
                                for (final tab in _Tab.values)
                                  ButtonSegment(
                                    value: tab,
                                    label: AppText(
                                      _labels[tab.index],
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      softWrap: false,
                                      style: TextStyle(
                                        fontFamily: Theme.of(
                                          context,
                                        ).textTheme.labelLarge?.fontFamily,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                              ],
                              selected: _tab,
                              onSelectionChanged: _busy ? (_) {} : _select,
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
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: StreamPathSectionSwitcher<_Tab>(
              selected: _tab,
              order: _Tab.values,
              shellBuilder: (_, _) => const SizedBox.expand(),
              contentBuilder: (_, tab) =>
                  tab == _contentTab ? _body() : const SizedBox.expand(),
              onSettled: (tab) => scheduleMicrotask(() => _activate(tab)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: AppText(_error!));
    if (_tabFiles.isNotEmpty && _document == null) {
      return const SizedBox.expand();
    }
    return DirectoryScrollView(
      key: ValueKey(_tab),
      builder: (controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        children: [
          for (final child in _content())
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: SizedBox(width: double.infinity, child: child),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _content() => switch (_tab) {
    _Tab.overview => _overview(),
    _Tab.options || _Tab.input => _editor(),
    _Tab.scripts => _scripts(),
    _Tab.shaders => _shaders(),
    _Tab.history => _historyWidgets(),
  };

  List<Widget> _overview() {
    final installation = _installation!;
    return [
      SettingsGroupCard(
        icon: SPIcons.playerSettings,
        title: '当前 MPV',
        description: '管理本地已有文件，修改不会重启或中断当前播放。',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              installation.executable,
              contextMenuBuilder: buildSPTextSelectionMenu,
            ),
            const SizedBox(height: 8),
            Text(
              _capabilities?.version ??
                  context.l10n.text(_probeError ?? '正在读取参数信息…'),
            ),
            const SizedBox(height: 8),
            const AppText('StreamPath 的会话参数和条件 profile 可能覆盖文件中的设置。'),
            if (!widget.player.argInjectionAllEnabled)
              const AppText('启动参数按媒体分类注入，实际配置来源可能随播放分类变化。'),
            if (!widget.player.argInjectionAllEnabled) ...[
              const SizedBox(height: 12),
              _ManagerField(
                label: '启动参数上下文',
                child: SPDropdownButtonFormField<int>(
                  initialValue: _mediaContext,
                  isExpanded: true,

                  items: [
                    for (var i = 0; i < 5; i++)
                      DropdownMenuItem(
                        value: i,
                        child: AppText(
                          ['无分类元数据', '电影', '剧集', '动漫电影', '动漫剧集'][i],
                        ),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value != null) {
                            setState(() => _mediaContext = value);
                            unawaited(_scan());
                          }
                        },
                ),
              ),
            ],
            const SizedBox(height: 12),
            SPButton(onPressed: _browse, label: const AppText('浏览其他配置目录')),
          ],
        ),
      ),
      const SizedBox(height: 16),
      SettingsGroupCard(
        icon: SPIcons.apps,
        title: '配置来源',
        description: '显示原始路径和加载依据；浏览目录不会更改播放器启动参数。',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final root in installation.roots)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SelectableText(
                  root,
                  contextMenuBuilder: buildSPTextSelectionMenu,
                ),
              ),
            if (installation.configDisabled)
              const AppText('启动参数关闭了配置读取，文件改动暂不参与播放。'),
            if (_browseRoot != null) const AppText('此目录仅供浏览，未改变当前播放器的配置来源。'),
            for (final file in installation.files)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(p.basename(file.path)),
                subtitle: Text(
                  '${file.origin}\n${file.exists ? file.path : context.l10n.format('{path}（尚不存在）', {'path': file.path})}',
                ),
                trailing: TextButton(
                  onPressed: () => _source(file.path, file.kind),
                  child: const AppText('源码'),
                ),
              ),
            for (final diagnostic in installation.diagnostics)
              AppText(switch (diagnostic) {
                'notFile' => '引用目标是目录，未作为配置文件读取。',
                'includeDepth' => 'include 层级超出限制，请通过源码查看。',
                'encoding' => '文件不是有效 UTF-8，已保留原文件并设为只读。',
                'noAutoScripts' => '此目录当前未自动加载脚本，文件启停不会覆盖全局设置。',
                _ => '仅管理本地文件，远程引用未读取。',
              }),
          ],
        ),
      ),
    ];
  }

  Future<void> _browse() async {
    final path = await _ask('浏览其他配置目录', '目录路径', '');
    if (path == null || !mounted) return;
    if (!await Directory(path).exists()) {
      _notice('操作失败，请检查文件是否存在、目录权限和磁盘空间。');
      return;
    }
    _browseRoot = path;
    await _scan();
  }

  List<Widget> _fileControls() {
    final files = _tabFiles;
    final doc = _document;
    if (files.isEmpty || doc == null) return [const AppText('没有找到可管理的文件。')];
    final scope = _ManagerField(
      label: '编辑作用域',
      child: SPDropdownButtonFormField<int>(
        key: ValueKey('${doc.path}-scope-$_block'),
        initialValue: _block,
        isExpanded: true,
        items: [
          const DropdownMenuItem(value: 0, child: AppText('全局设置')),
          for (final line in doc.lines.where(
            (l) => l.kind == MpvLineKind.section,
          ))
            DropdownMenuItem(
              value: line.block,
              child: Text('[${line.scope}] · ${line.number}'),
            ),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _block = value);
        },
      ),
    );
    final category = _ManagerField(
      label: doc.kind == MpvDocumentKind.input ? '命令分类' : '参数分类',
      child: SPDropdownButtonFormField<String>(
        key: ValueKey('${doc.path}-category'),
        initialValue: doc.kind == MpvDocumentKind.input
            ? (doc.entries.any(
                    (line) => _inputCategory(line) == _commandCategory,
                  )
                  ? _commandCategory
                  : '全部命令')
            : _category,
        isExpanded: true,
        items: [
          for (final name
              in doc.kind == MpvDocumentKind.input
                  ? [
                      '全部命令',
                      ...doc.entries
                          .map(_inputCategory)
                          .where((name) => name != '全部命令')
                          .toSet(),
                    ]
                  : ['全部参数', '视频', '音频', '字幕', '窗口', '网络与缓存', '其他参数'])
            DropdownMenuItem(value: name, child: AppText(name)),
        ],
        onChanged: (value) {
          if (value != null) {
            setState(() {
              if (doc.kind == MpvDocumentKind.input) {
                _commandCategory = value;
              } else {
                _category = value;
              }
            });
          }
        },
      ),
    );
    return [
      SettingsGroupCard(
        icon: SPIcons.playerSettings,
        title: '配置与筛选',
        description: '选择原始文件与编辑范围，完成修改后自动保存。',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ManagerField(
              label: '配置文件',
              child: SPDropdownButtonFormField<String>(
                key: ValueKey('files-${_tab.name}-${doc.path}'),
                initialValue: files.any((f) => f.path == doc.path)
                    ? doc.path
                    : files.first.path,
                isExpanded: true,
                items: files
                    .map(
                      (f) => DropdownMenuItem(
                        value: f.path,
                        child: Text(
                          (f.path == doc.path ? doc.exists : f.exists)
                              ? f.path
                              : context.l10n.format('{path}（尚不存在）', {
                                  'path': f.path,
                                }),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) {
                          unawaited(
                            _perform(
                              () => _open(
                                files.firstWhere((f) => f.path == value),
                              ),
                            ),
                          );
                        }
                      },
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: () => _source(doc.path, doc.kind),
                  child: const AppText('源码'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _perform(
                          () => _open(MpvManagedFile(doc.path, doc.kind, '')),
                        ),
                  child: const AppText('重新加载'),
                ),
                TextButton(
                  onPressed: _busy || _external || doc.text == null
                      ? null
                      : _add,
                  child: const AppText('新增项目'),
                ),
                if (doc.kind == MpvDocumentKind.options)
                  TextButton(
                    onPressed: _busy || _external ? null : _addProfile,
                    child: const AppText('新增 profile'),
                  ),
              ],
            ),
            if (_external) _description('文件已在外部修改，请重新加载后再编辑。'),
            if (doc.text == null) _description('文件不是有效 UTF-8，已保留原文件并设为只读。'),
            if (doc.lines.any((l) => l.kind == MpvLineKind.invalid))
              _description('部分行无法解析，已保留原文，可通过源码编辑。'),
            if (!doc.exists) _description('文件尚不存在，首次完成修改时创建。'),
            if (doc.kind == MpvDocumentKind.options) ...[
              const SizedBox(height: 16),
              if (_tab == _Tab.shaders)
                scope
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final wide =
                        constraints.maxWidth >=
                        680 * MediaQuery.textScalerOf(context).scale(1);
                    return wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: scope),
                              const SizedBox(width: 16),
                              Expanded(child: category),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              scope,
                              const SizedBox(height: 16),
                              category,
                            ],
                          );
                  },
                ),
            ],
            if (doc.kind == MpvDocumentKind.input) ...[
              const SizedBox(height: 12),
              category,
            ],
            if (_tab != _Tab.shaders) ...[
              const SizedBox(height: 16),
              _ManagerField(
                label: '搜索参数、按键或命令',
                child: TextField(
                  controller: _search,
                  contextMenuBuilder: buildClipboardHistoryMenu,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  List<Widget> _editor() {
    final doc = _document;
    final schema = _currentScriptSchema;
    final entries =
        doc?.entries
            .where(
              (line) =>
                  (doc.kind != MpvDocumentKind.options ||
                      line.block == _block &&
                          (line.enabled ||
                              line.value.isNotEmpty ||
                              _capabilities?.optionNames.contains(line.key) ==
                                  true ||
                              latin1
                                  .decode(
                                    doc.bytes.sublist(
                                      line.start,
                                      line.contentEnd,
                                    ),
                                  )
                                  .contains('=')) &&
                          (_category == '全部参数' ||
                              _optionCategory(line.key) == _category)) &&
                  (doc.kind != MpvDocumentKind.input ||
                      _commandCategory == '全部命令' ||
                      _inputCategory(line) == _commandCategory) &&
                  '${line.key} ${line.value} ${line.menuPath}'
                      .toLowerCase()
                      .contains(_search.text.toLowerCase()),
            )
            .toList() ??
        [];
    return [
      ..._fileControls(),
      if (schema != null && doc != null) ...[
        const AppText('已验证的插件参数'),
        const AppText('只有匹配已验证脚本内容时才提供类型化控件。'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in schema.options.values.where(
              (option) => !doc.entries.any((line) => line.key == option.name),
            ))
              TextButton(
                onPressed: _busy || _external
                    ? null
                    : () => _perform(
                        () => _commit(
                          doc,
                          doc.addEntry(option.name, '${option.defaultValue}'),
                        ),
                      ),
                child: Text(
                  context.l10n.format('添加 {name}', {'name': option.name}),
                ),
              ),
          ],
        ),
      ],
      if (doc != null)
        for (final line in entries) _entry(doc, line),
      if (entries.isEmpty) const AppText('此作用域没有匹配项目，可新增参数或打开源码。'),
    ];
  }

  Widget _entry(MpvDocumentSnapshot doc, MpvLine line) {
    final info = doc.kind == MpvDocumentKind.scriptOptions
        ? _currentScriptSchema?.options[line.key]
        : _capabilities?.options[line.key];
    final disabled = _busy || _external || doc.text == null;
    final conflicts =
        doc.kind == MpvDocumentKind.input &&
        line.enabled &&
        doc.entries
                .where(
                  (other) =>
                      other.enabled &&
                      other.key == line.key &&
                      other.inputSection == line.inputSection,
                )
                .length >
            1;
    final theme = Theme.of(context);
    final actions = Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        TextButton(
          onPressed: disabled || line.menuOnly
              ? null
              : () => _changeKey(doc, line),
          child: AppText(doc.kind == MpvDocumentKind.input ? '修改按键' : '修改名称'),
        ),
        TextButton(
          onPressed: disabled ? null : () => _delete(doc, line),
          child: const AppText('删除'),
        ),
      ],
    );
    final identity = Row(
      children: [
        Tooltip(
          message: context.l10n.text('启用此行'),
          child: Switch(
            value: line.enabled,
            onChanged: disabled || line.menuOnly
                ? null
                : (value) =>
                      _perform(() => _commit(doc, doc.setEnabled(line, value))),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                line.menuOnly ? context.l10n.text('仅菜单项') : line.key,
                style: theme.textTheme.titleSmall,
                contextMenuBuilder: buildSPTextSelectionMenu,
              ),
              const SizedBox(height: 4),
              Text(
                '${context.l10n.format('第 {line} 行', {'line': line.number})}${line.inputSection.isEmpty ? '' : ' · {${line.inputSection}}'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide =
                  constraints.maxWidth >=
                  1050 * MediaQuery.textScalerOf(context).scale(1);
              final input = doc.kind == MpvDocumentKind.input;
              final value = _entryValue(doc, line, info, disabled);
              Widget field(String label, Widget child) => wide
                  ? Tooltip(
                      message: context.l10n.text(label),
                      child: Semantics(
                        label: context.l10n.text(label),
                        child: child,
                      ),
                    )
                  : _ManagerField(label: label, child: child);
              final metadata = info == null
                  ? ''
                  : context.l10n.format('类型：{type} · 默认：{value}', {
                      'type': info.type,
                      'value': info.defaultValue ?? '',
                    });
              final name = metadata.isEmpty
                  ? identity
                  : Tooltip(message: metadata, child: identity);
              final fieldWidth = wide
                  ? (constraints.maxWidth - 210 - 210 - (input ? 36 : 24)) /
                        (input ? 2 : 1)
                  : constraints.maxWidth;
              return Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: wide ? 210 : constraints.maxWidth,
                    child: name,
                  ),
                  SizedBox(
                    width: fieldWidth,
                    child: field(input ? '命令' : '参数值', value),
                  ),
                  if (input)
                    SizedBox(
                      width: fieldWidth,
                      child: field(
                        '菜单路径',
                        _AutoValueField(
                          key: ValueKey(
                            '${doc.path}-${doc.revision}-${line.start}-menu',
                          ),
                          value: line.menuPath,
                          enabled: !disabled,
                          onCommit: (value) =>
                              _commit(doc, doc.setMenuPath(line, value)),
                          errorText: _message,
                        ),
                      ),
                    ),
                  SizedBox(
                    width: wide ? 210 : constraints.maxWidth,
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: actions,
                    ),
                  ),
                  if (conflicts)
                    const AppText('此 section 中存在同名按键，后续声明或脚本可能覆盖它。'),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _entryValue(
    MpvDocumentSnapshot doc,
    MpvLine line,
    MpvOptionInfo? info,
    bool disabled,
  ) {
    if (info?.type == 'Flag' && ['yes', 'no', ''].contains(line.value)) {
      return SPDropdownButtonFormField<String>(
        key: ValueKey('${doc.revision}-${line.start}-flag'),
        initialValue: line.value.isEmpty ? 'yes' : line.value,
        isExpanded: true,
        items: const [
          DropdownMenuItem(value: 'yes', child: Text('yes')),
          DropdownMenuItem(value: 'no', child: Text('no')),
        ],
        onChanged: disabled
            ? null
            : (value) {
                if (value != null) {
                  unawaited(
                    _perform(() => _commit(doc, doc.setValue(line, value))),
                  );
                }
              },
      );
    }
    if (info?.type == 'Choices' && info!.choices.contains(line.value)) {
      return SPDropdownButtonFormField<String>(
        key: ValueKey('${doc.revision}-${line.start}-choice'),
        initialValue: line.value,
        isExpanded: true,
        items: info.choices
            .map(
              (choice) => DropdownMenuItem(value: choice, child: Text(choice)),
            )
            .toList(),
        onChanged: disabled
            ? null
            : (value) {
                if (value != null) {
                  unawaited(
                    _perform(() => _commit(doc, doc.setValue(line, value))),
                  );
                }
              },
      );
    }
    return _AutoValueField(
      key: ValueKey('${doc.path}-${doc.revision}-${line.start}'),
      value: line.value,
      enabled: !disabled,
      validate: info?.validate,
      onCommit: (value) => _commit(doc, doc.setValue(line, value)),
      errorText: _message,
    );
  }

  Widget _description(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: AppText(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Future<void> _changeKey(MpvDocumentSnapshot doc, MpvLine line) async {
    final value = await _ask(
      doc.kind == MpvDocumentKind.input ? '修改按键' : '修改名称',
      '名称或按键',
      line.key,
      recordKey: doc.kind == MpvDocumentKind.input,
    );
    if (value != null) {
      await _perform(() => _commit(doc, doc.setKey(line, value)));
    }
  }

  Future<void> _delete(MpvDocumentSnapshot doc, MpvLine line) async {
    if (await _confirm('删除此项仅移除对应行，其他内容保持原样。') == true) {
      await _perform(() => _commit(doc, doc.remove(line)));
    }
  }

  Future<void> _addProfile() async {
    final doc = _document!;
    final name = await _ask('新增 profile', '名称或按键', '');
    if (name != null) await _perform(() => _commit(doc, doc.addProfile(name)));
  }

  Future<void> _add() async {
    final doc = _document!;
    final value = await showGlassDialog<(String, String)>(
      context: context,
      builder: (_) => _AddEntryDialog(
        input: doc.kind == MpvDocumentKind.input,
        optionNames: doc.kind == MpvDocumentKind.scriptOptions
            ? _currentScriptSchema?.options.keys.toList() ?? []
            : _capabilities?.optionNames ?? [],
        commands: _capabilities?.commands ?? [],
      ),
    );
    if (value != null) {
      await _perform(
        () => _commit(doc, doc.addEntry(value.$1, value.$2, block: _block)),
      );
    }
  }

  List<Widget> _scripts() => [
    _description('自动加载脚本可启停；显式加载请编辑对应声明。自定义加载器的动态内容通过源码管理。'),
    if (_installation!.diagnostics.contains('noAutoScripts'))
      const AppText('此目录当前未自动加载脚本，文件启停不会覆盖全局设置。'),
    const SizedBox(height: 12),
    for (final script in _installation!.scripts)
      _resourceCard(
        title: script.source == null
            ? context.l10n.format('{path}（尚不存在）', {
                'path': p.basename(script.path),
              })
            : p.basename(script.path),
        path:
            '${script.path}\n${context.l10n.text(script.explicit ? '存在显式加载声明，请在 MPV 参数中管理。' : '自动加载目录')}',
        leading: Switch(
          value: !script.disabled,
          onChanged: _busy || !script.automatic || script.explicit
              ? null
              : (enabled) => _perform(() async {
                  await widget.store.renameScript(script.path, enabled);
                  await _scan();
                }),
        ),
        actions: [
          if (script.source != null)
            TextButton(
              onPressed: () => _source(script.source!, MpvDocumentKind.source),
              child: const AppText('源码'),
            ),
          if (script.configPath != null)
            TextButton(
              onPressed: () async {
                _select(_Tab.scripts);
                await _perform(
                  () => _open(
                    MpvManagedFile(
                      script.configPath!,
                      MpvDocumentKind.scriptOptions,
                      'script-opts',
                    ),
                  ),
                );
              },
              child: const AppText('配置'),
            ),
          TextButton(
            onPressed: () => _associate(script),
            child: const AppText('关联配置'),
          ),
        ],
      ),
    const Divider(height: 32),
    AppText('脚本配置', style: Theme.of(context).textTheme.titleMedium),
    _description('按脚本自身规则读取键和值，未知参数保持文本编辑。'),
    const SizedBox(height: 12),
    ..._editor(),
  ];

  Widget _resourceCard({
    required String title,
    required String path,
    Widget? leading,
    required List<Widget> actions,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (leading != null) ...[leading, const SizedBox(width: 12)],
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              path,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              contextMenuBuilder: buildSPTextSelectionMenu,
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ),
      ),
    ),
  );

  Future<void> _associate(MpvLocalScript script) async {
    final path = await _ask(
      '关联配置',
      '配置文件路径',
      script.configPath ??
          p.join(
            _installation!.roots.first,
            'script-opts',
            '${p.basenameWithoutExtension(script.path)}.conf',
          ),
    );
    if (path == null) return;
    await _perform(() async {
      await widget.store.associate(script.path, path);
      await _scan();
      await _open(
        MpvManagedFile(path, MpvDocumentKind.scriptOptions, 'script-opts'),
      );
    });
  }

  MpvScriptSchema? get _currentScriptSchema {
    final document = _document;
    if (document?.kind != MpvDocumentKind.scriptOptions) return null;
    for (final script in _installation!.scripts) {
      if (script.configPath != null &&
          p.equals(script.configPath!, document!.path)) {
        return script.schema;
      }
    }
    return null;
  }

  List<Widget> _shaders() {
    final doc = _document;
    final lines =
        doc?.entries
            .where(
              (l) =>
                  l.block == _block &&
                  [
                    'glsl-shader',
                    'glsl-shaders',
                    'glsl-shaders-append',
                  ].contains(l.key),
            )
            .toList() ??
        [];
    return [
      _description('启停和排序只修改所选声明中的引用，着色器文件保留原名。'),
      ..._fileControls(),
      if (doc != null)
        for (final line in lines) ...[
          _entry(doc, line),
          if (line.key == 'glsl-shaders' && line.enabled)
            _shaderOrder(doc, line),
        ],
      const Divider(height: 32),
      AppText('本地着色器文件', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      for (final shader in _installation!.shaders)
        _resourceCard(
          title: p.basename(shader),
          path: shader,
          actions: [
            TextButton(
              onPressed: () => _source(shader, MpvDocumentKind.source),
              child: const AppText('源码'),
            ),
            TextButton(
              onPressed: doc == null || _busy || _external
                  ? null
                  : () => _perform(
                      () => _commit(
                        doc,
                        doc.addEntry('glsl-shader', shader, block: _block),
                      ),
                    ),
              child: const AppText('加入当前作用域'),
            ),
          ],
        ),
    ];
  }

  Widget _shaderOrder(MpvDocumentSnapshot doc, MpvLine line) {
    final paths = splitMpvPathTokens(line.value);
    return ReorderableListView.builder(
      key: ValueKey('${doc.revision}-${line.start}-order'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      proxyDecorator: spReorderProxy,
      itemCount: paths.length,
      onReorderItem: (oldIndex, newIndex) {
        if (_busy || _external) return;
        paths.insert(newIndex, paths.removeAt(oldIndex));
        unawaited(
          _perform(
            () => _commit(
              doc,
              doc.setValue(line, paths.join(Platform.isWindows ? ';' : ':')),
            ),
          ),
        );
      },
      itemBuilder: (context, index) => ListTile(
        key: ValueKey('$index-${paths[index]}'),
        leading: SPReorderHandle(
          index: index,
          tooltip: context.l10n.text('调整顺序'),
          enabled: !_busy && !_external,
        ),
        title: Text(paths[index]),
        trailing: TextButton(
          onPressed: _busy || _external
              ? null
              : () {
                  paths.removeAt(index);
                  unawaited(
                    _perform(
                      () => _commit(
                        doc,
                        doc.setValue(
                          line,
                          paths.join(Platform.isWindows ? ';' : ':'),
                        ),
                      ),
                    ),
                  );
                },
          child: const AppText('移除引用'),
        ),
      ),
    );
  }

  List<Widget> _historyWidgets() => [
    _description('恢复会核对当前内容；外部修改过的文件不会被旧备份覆盖。'),
    if (_history.isEmpty) const AppText('暂无更改记录。'),
    for (final entry in _history)
      _resourceCard(
        title: p.basename(entry.path),
        path: '${entry.time.toLocal()}\n${entry.path}',
        actions: [
          TextButton(
            onPressed: () => _showDiff(entry),
            child: const AppText('查看差异'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    if (await _confirm('恢复此版本的修改前内容？') != true) return;
                    await _perform(() async {
                      await widget.store.restore(entry);
                      await _scan();
                    });
                  },
            child: const AppText('恢复'),
          ),
        ],
      ),
  ];

  Future<void> _showDiff(MpvHistoryEntry entry) async {
    final before = utf8.decode(entry.before), after = utf8.decode(entry.after);
    await showGlassDialog<void>(
      context: context,
      builder: (dialogContext) => SPDialog(
        title: const AppText('查看差异'),
        content: SizedBox(
          width: 850,
          height: 450,
          child: DirectoryScrollView(
            builder: (controller) => SingleChildScrollView(
              controller: controller,
              child: SelectableText(
                _diff(before, after),
                contextMenuBuilder: buildSPTextSelectionMenu,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const AppText('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _source(String path, MpvDocumentKind kind) => _perform(() async {
    final doc = await widget.store.load(path, kind);
    if (!mounted) return;
    if (doc.text == null) {
      _notice('文件不是有效 UTF-8，已保留原文件并设为只读。');
      return;
    }
    await showGlassDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SourceDialog(
        document: doc,
        save: (text) => _commit(doc, doc.replaceText(text)),
        errorText: _message,
      ),
    );
  });

  Future<bool?> _confirm(String message) => showGlassDialog<bool>(
    context: context,
    builder: (dialogContext) => SPDialog(
      content: AppText(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const AppText('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const AppText('确定'),
        ),
      ],
    ),
  );

  Future<String?> _ask(
    String title,
    String label,
    String initial, {
    bool recordKey = false,
  }) => showGlassDialog<String>(
    context: context,
    builder: (_) => _ValueDialog(title, label, initial, recordKey: recordKey),
  );
}

/// 与设置页一致的独立标签，避免浮动标签越过控件和滚动裁剪边界。
class _ManagerField extends StatelessWidget {
  const _ManagerField({required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: ExcludeSemantics(
          child: AppText(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      Semantics(label: context.l10n.text(label), child: child),
    ],
  );
}

class _AutoValueField extends StatefulWidget {
  const _AutoValueField({
    super.key,
    required this.value,
    required this.enabled,
    required this.onCommit,
    required this.errorText,
    this.validate,
  });
  final String value;
  final bool enabled;
  final String? Function(String)? validate;
  final Future<void> Function(String) onCommit;
  final String Function(Object) errorText;
  @override
  State<_AutoValueField> createState() => _AutoValueFieldState();
}

class _AutoValueFieldState extends State<_AutoValueField> {
  late final _controller = TextEditingController(text: widget.value);
  final _focus = FocusNode();
  String? _error;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _focus.addListener(_blur);
  }

  void _blur() {
    if (!_focus.hasFocus) unawaited(_save());
  }

  Future<void> _save() async {
    if (_saving || !widget.enabled || _controller.text == widget.value) return;
    if (widget.validate?.call(_controller.text) != null) {
      setState(() => _error = '参数值不符合当前 MPV 的类型或范围。');
      return;
    }
    _saving = true;
    try {
      await widget.onCommit(_controller.text);
    } on Object catch (error) {
      if (mounted) setState(() => _error = widget.errorText(error));
    } finally {
      _saving = false;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_blur);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    focusNode: _focus,
    enabled: widget.enabled,
    contextMenuBuilder: buildClipboardHistoryMenu,
    onSubmitted: (_) => _save(),
    minLines: 1,
    maxLines: 3,
    keyboardType: TextInputType.text,
    textInputAction: TextInputAction.done,
    decoration: InputDecoration(
      errorText: _error == null ? null : context.l10n.text(_error!),
    ),
  );
}

class _ValueDialog extends StatefulWidget {
  const _ValueDialog(
    this.title,
    this.label,
    this.initial, {
    this.recordKey = false,
  });
  final String title, label, initial;
  final bool recordKey;
  @override
  State<_ValueDialog> createState() => _ValueDialogState();
}

class _ValueDialogState extends State<_ValueDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  bool _recording = false;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SPDialog(
    title: AppText(widget.title),
    content: SizedBox(
      width: 500,
      child: Focus(
        onKeyEvent: (_, event) {
          if (!_recording || event is! KeyDownEvent) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          if ([
            LogicalKeyboardKey.controlLeft,
            LogicalKeyboardKey.controlRight,
            LogicalKeyboardKey.shiftLeft,
            LogicalKeyboardKey.shiftRight,
            LogicalKeyboardKey.altLeft,
            LogicalKeyboardKey.altRight,
            LogicalKeyboardKey.metaLeft,
            LogicalKeyboardKey.metaRight,
          ].contains(key)) {
            return KeyEventResult.handled;
          }
          final names = {
            LogicalKeyboardKey.arrowLeft: 'LEFT',
            LogicalKeyboardKey.arrowRight: 'RIGHT',
            LogicalKeyboardKey.arrowUp: 'UP',
            LogicalKeyboardKey.arrowDown: 'DOWN',
            LogicalKeyboardKey.space: 'SPACE',
            LogicalKeyboardKey.enter: 'ENTER',
            LogicalKeyboardKey.escape: 'ESC',
            LogicalKeyboardKey.backspace: 'BS',
            LogicalKeyboardKey.delete: 'DEL',
            LogicalKeyboardKey.pageUp: 'PGUP',
            LogicalKeyboardKey.pageDown: 'PGDWN',
            LogicalKeyboardKey.home: 'HOME',
            LogicalKeyboardKey.end: 'END',
            LogicalKeyboardKey.tab: 'TAB',
          };
          final keyboard = HardwareKeyboard.instance;
          var name = names[key] ?? key.keyLabel;
          final character = event.character;
          final printable =
              character != null &&
              character.runes.length == 1 &&
              character.runes.single >= 32 &&
              character.runes.single != 127;
          if (printable && !names.containsKey(key)) name = character;
          if (name.length == 1) {
            name = printable
                ? name
                : keyboard.isShiftPressed
                ? name.toUpperCase()
                : name.toLowerCase();
          }
          if (name == '#') name = 'SHARP';
          _controller.text =
              '${keyboard.isControlPressed ? 'Ctrl+' : ''}${keyboard.isAltPressed ? 'Alt+' : ''}${keyboard.isMetaPressed ? 'Meta+' : ''}${keyboard.isShiftPressed && !printable && name.length > 1 ? 'Shift+' : ''}$name';
          setState(() => _recording = false);
          return KeyEventResult.handled;
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ManagerField(
              label: widget.label,
              child: TextField(
                controller: _controller,
                autofocus: true,
                contextMenuBuilder: buildClipboardHistoryMenu,
              ),
            ),
            if (widget.recordKey) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => setState(() => _recording = !_recording),
                child: AppText(_recording ? '请按下快捷键…' : '录入快捷键'),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const AppText('取消'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const AppText('确定'),
      ),
    ],
  );
}

class _AddEntryDialog extends StatefulWidget {
  const _AddEntryDialog({
    required this.input,
    required this.optionNames,
    required this.commands,
  });
  final bool input;
  final List<String> optionNames, commands;
  @override
  State<_AddEntryDialog> createState() => _AddEntryDialogState();
}

class _AddEntryDialogState extends State<_AddEntryDialog> {
  final _key = TextEditingController(),
      _value = TextEditingController(),
      _filter = TextEditingController();
  @override
  void dispose() {
    _key.dispose();
    _value.dispose();
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final choices = (widget.input ? widget.commands : widget.optionNames)
        .where((name) => name.contains(_filter.text))
        .take(80)
        .toList();
    return SPDialog(
      title: const AppText('新增项目'),
      content: SizedBox(
        width: 600,
        height: 330,
        child: DirectoryScrollView(
          builder: (controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            children: [
              _ManagerField(
                label: '名称或按键',
                child: TextField(
                  controller: _key,
                  contextMenuBuilder: buildClipboardHistoryMenu,
                ),
              ),
              const SizedBox(height: 16),
              _ManagerField(
                label: widget.input ? '命令' : '参数值',
                child: TextField(
                  controller: _value,
                  contextMenuBuilder: buildClipboardHistoryMenu,
                ),
              ),
              const SizedBox(height: 16),
              _ManagerField(
                label: '搜索可用选项或命令',
                child: TextField(
                  controller: _filter,
                  contextMenuBuilder: buildClipboardHistoryMenu,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (choices.isNotEmpty) ...[
                const SizedBox(height: 16),
                _ManagerField(
                  label: '选择建议',
                  child: SPDropdownButtonFormField<String>(
                    key: ValueKey(_filter.text),
                    isExpanded: true,
                    items: choices
                        .map(
                          (name) =>
                              DropdownMenuItem(value: name, child: Text(name)),
                        )
                        .toList(),
                    onChanged: (name) {
                      if (name != null) {
                        (widget.input ? _value : _key).text = name;
                      }
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const AppText('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop((_key.text, _value.text)),
          child: const AppText('确定'),
        ),
      ],
    );
  }
}

class _SourceDialog extends StatefulWidget {
  const _SourceDialog({
    required this.document,
    required this.save,
    required this.errorText,
  });
  final MpvDocumentSnapshot document;
  final Future<void> Function(String) save;
  final String Function(Object) errorText;
  @override
  State<_SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends State<_SourceDialog> {
  late final _text = TextEditingController(
    text: widget.document.text!.replaceFirst(RegExp('^\uFEFF'), ''),
  );
  bool _saving = false, _preview = false;
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: SPDialog(
      title: Tooltip(
        message: widget.document.path,
        child: Text(
          widget.document.path,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      content: SizedBox(
        width: 1000,
        height: 550,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppText('源码编辑不会执行脚本或编译着色器；请确认差异后写回。'),
            if (_error != null) AppText(_error!),
            const SizedBox(height: 12),
            Expanded(
              child: DirectoryScrollView(
                builder: (controller) => SingleChildScrollView(
                  controller: controller,
                  child: _preview
                      ? SelectableText(
                          _diff(widget.document.text!, _text.text),
                          contextMenuBuilder: buildSPTextSelectionMenu,
                        )
                      : TextField(
                          controller: _text,
                          enabled: !_saving,
                          maxLines: null,
                          minLines: 20,
                          contextMenuBuilder: buildClipboardHistoryMenu,
                          style: const TextStyle(fontFamily: 'monospace'),
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const AppText('取消'),
        ),
        TextButton(
          onPressed: _saving
              ? null
              : () => setState(() => _preview = !_preview),
          child: AppText(_preview ? '继续编辑' : '查看差异'),
        ),
        TextButton(
          onPressed: _saving
              ? null
              : () async {
                  setState(() {
                    _saving = true;
                    _error = null;
                  });
                  try {
                    await widget.save(_text.text);
                    if (context.mounted) Navigator.of(context).pop();
                  } on Object catch (error) {
                    if (mounted) {
                      setState(() => _error = widget.errorText(error));
                    }
                  } finally {
                    if (mounted) setState(() => _saving = false);
                  }
                },
          child: const AppText('确认修改'),
        ),
      ],
    ),
  );
}

String _diff(String before, String after) {
  final a = before.split('\n'), b = after.split('\n');
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var endA = a.length, endB = b.length;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }
  return [
    for (var i = start; i < endA; i++) '- ${a[i]}',
    for (var i = start; i < endB; i++) '+ ${b[i]}',
  ].join('\n');
}

String _optionCategory(String key) {
  if (RegExp(r'^(sub-|sid$|slang$|ass-|embeddedfonts)').hasMatch(key)) {
    return '字幕';
  }
  if (RegExp(r'^(audio-|ao$|af$|aid$|alang$|volume|mute$)').hasMatch(key)) {
    return '音频';
  }
  if (RegExp(
    r'^(cache|demuxer-|stream-|network-|http-|ytdl|tls-)',
  ).hasMatch(key)) {
    return '网络与缓存';
  }
  if (RegExp(
    r'^(window|fullscreen|fs$|border|ontop|geometry|autofit|screen|keepaspect|title)',
  ).hasMatch(key)) {
    return '窗口';
  }
  if (RegExp(
    r'^(video-|vo$|vf$|hwdec|gpu-|glsl-|scale|cscale|dscale|deband|interpolation|tone-mapping|target-|dither)',
  ).hasMatch(key)) {
    return '视频';
  }
  return '其他参数';
}

String _inputCategory(MpvLine line) {
  if (line.menuPath.isNotEmpty) return line.menuPath.split('>').first.trim();
  final command = line.value;
  final property = RegExp(
    r'(?:set|cycle|add|multiply|cycle-values)\s+([\w-]+)',
  ).firstMatch(command)?[1];
  if (property != null && _optionCategory(property) != '其他参数') {
    return _optionCategory(property);
  }
  if (RegExp(r'glsl-|shader|Anime4K', caseSensitive: false).hasMatch(command)) {
    return '着色器';
  }
  if (RegExp(
    r'^(?:seek|playlist-|frame-|stop|quit|revert-seek|ab-loop)',
  ).hasMatch(command)) {
    return '播放与导航';
  }
  if (RegExp(r'^(?:loadfile|loadlist|sub-add|audio-add)').hasMatch(command)) {
    return '文件';
  }
  if (RegExp(r'^(?:script-binding|script-message)').hasMatch(command)) {
    return '脚本命令';
  }
  return '其他命令';
}
