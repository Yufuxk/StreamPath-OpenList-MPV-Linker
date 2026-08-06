import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/extension_filter.dart';
import '../../core/utils/file_sort.dart';
import '../../data/models/connection_config.dart';
import '../../data/models/player_config.dart';
import '../../data/models/stream_path_config.dart';
import '../../domain/services/external_player_service.dart';
import '../state/app_state.dart';
import '../widgets/clipboard_history_menu.dart';

/// 播放器设置页：外部播放器路径、启动参数模板、字幕/续播开关。
///
/// 参数模板按行编辑（每行一个参数），支持占位符：
/// `{url}` 视频地址 · `{subfile}` 字幕地址 · `{start}` 续播秒数；
/// 无值的占位符所在的整行参数会被自动移除。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _executableController;
  late final TextEditingController _argsController;
  late final TextEditingController _hiddenExtensionsController;
  late final TextEditingController _serverUrlController;
  late final TextEditingController _serverUsernameController;
  late final TextEditingController _serverPasswordController;

  bool _subtitleInjectionEnabled = true;
  bool _subtitleAutoSelectEnabled = true;
  bool _resumeEnabled = true;
  FileSortMode _defaultSortMode = FileSortMode.name;
  FileSortDirection _defaultSortDirection = FileSortDirection.ascending;
  int _playerStartupTimeoutSeconds =
      AppConstants.defaultPlayerStartupTimeoutSeconds;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _executableController = TextEditingController();
    _argsController = TextEditingController();
    _hiddenExtensionsController = TextEditingController();
    _serverUrlController = TextEditingController();
    _serverUsernameController = TextEditingController();
    _serverPasswordController = TextEditingController();
    _loadConfig();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _executableController.dispose();
    _argsController.dispose();
    _hiddenExtensionsController.dispose();
    _serverUrlController.dispose();
    _serverUsernameController.dispose();
    _serverPasswordController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final appState = context.read<AppState>();
      final config = await appState.configStore.loadPlayer();
      final connection = await appState.configStore.loadConnection();
      if (!mounted) return;
      setState(() {
        _nameController.text = config.name;
        _executableController.text = config.executable;
        _argsController.text = config.args.join('\n');
        _hiddenExtensionsController.text = formatHiddenExtensions(
          config.hiddenExtensions,
        );
        _serverUrlController.text = connection.baseUrl;
        _serverUsernameController.text = connection.username;
        _serverPasswordController.text = connection.password;
        _subtitleInjectionEnabled = config.subtitleInjectionEnabled;
        _subtitleAutoSelectEnabled = config.subtitleAutoSelectEnabled;
        _resumeEnabled = config.resumeEnabled;
        _defaultSortMode = config.defaultSortMode;
        _defaultSortDirection = config.defaultSortDirection;
        _playerStartupTimeoutSeconds = config.playerStartupTimeoutSeconds;
        _loaded = true;
      });
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final config = PlayerConfig(
      name: _nameController.text.trim().isEmpty
          ? '外部播放器'
          : _nameController.text.trim(),
      executable: _executableController.text.trim(),
      args: _argsController.text
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      subtitleInjectionEnabled: _subtitleInjectionEnabled,
      subtitleAutoSelectEnabled:
          _subtitleInjectionEnabled && _subtitleAutoSelectEnabled,
      resumeEnabled: _resumeEnabled,
      hiddenExtensions: parseHiddenExtensions(_hiddenExtensionsController.text),
      defaultSortMode: _defaultSortMode,
      defaultSortDirection: _defaultSortDirection,
      playerStartupTimeoutSeconds: _playerStartupTimeoutSeconds,
    );

    setState(() => _saving = true);
    try {
      final appState = context.read<AppState>();
      final connection = ConnectionConfig(
        baseUrl: _serverUrlController.text.trim(),
        username: _serverUsernameController.text.trim(),
        password: _serverPasswordController.text,
      );
      await appState.configStore.save(
        StreamPathConfig.fromParts(config, connection),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('播放器配置已保存')));
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _resetToDefault() {
    final def = PlayerConfig.defaultMpv();
    setState(() {
      _nameController.text = def.name;
      _executableController.text = def.executable;
      _argsController.text = def.args.join('\n');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('播放器设置'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('保存'),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _nameController,
                          contextMenuBuilder: buildClipboardHistoryMenu,
                          decoration: const InputDecoration(
                            labelText: '播放器名称',
                            hintText: 'mpv / PotPlayer / VLC',
                            prefixIcon: Icon(Icons.movie_filter_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _executableController,
                          contextMenuBuilder: buildClipboardHistoryMenu,
                          decoration: const InputDecoration(
                            labelText: '可执行文件路径',
                            hintText: 'mpv 或 C:\\Program Files\\mpv\\mpv.exe',
                            prefixIcon: Icon(Icons.apps_outlined),
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) {
                            final s = v?.trim() ?? '';
                            if (s.isEmpty) return '请输入播放器路径';
                            // 绝对/相对路径时校验文件存在性。
                            final problem =
                                ExternalPlayerService(
                                  configStore: context
                                      .read<AppState>()
                                      .configStore,
                                ).validateExecutable(
                                  PlayerConfig(
                                    name: _nameController.text,
                                    executable: s,
                                    args: const [],
                                  ),
                                );
                            return problem;
                          },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _argsController,
                          maxLines: 6,
                          contextMenuBuilder: buildClipboardHistoryMenu,
                          decoration: const InputDecoration(
                            labelText: '启动参数（每行一个）',
                            helperText:
                                '占位符：{url} 视频地址 · {subfile} 字幕地址 · {start} 续播秒数\n无值的占位符所在行会自动移除',
                            alignLabelWithHint: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _resetToDefault,
                            icon: const Icon(Icons.restore, size: 18),
                            label: const Text('恢复默认（mpv 模板）'),
                          ),
                        ),
                        const Divider(),
                        TextFormField(
                          controller: _hiddenExtensionsController,
                          contextMenuBuilder: buildClipboardHistoryMenu,
                          decoration: const InputDecoration(
                            labelText: '隐藏文件后缀（仅界面隐藏）',
                            helperText:
                                '格式：{".ass", ".mp4", ".mp3"}（逗号/空格分隔均可）\n隐藏仅作用于文件列表显示，后台引用与字幕加载不受影响',
                            prefixIcon: Icon(Icons.visibility_off_outlined),
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) {
                            try {
                              parseHiddenExtensions(v ?? '');
                              return null;
                            } on FormatException catch (e) {
                              return e.message;
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<FileSortMode>(
                          initialValue: _defaultSortMode,
                          decoration: const InputDecoration(
                            labelText: '默认排序方式',
                            helperText: '软件启动后文件浏览页默认使用的排序规则',
                            prefixIcon: Icon(Icons.sort),
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final mode in FileSortMode.values)
                              DropdownMenuItem<FileSortMode>(
                                value: mode,
                                child: Text(mode.label),
                              ),
                          ],
                          onChanged: (mode) {
                            if (mode != null) {
                              setState(() => _defaultSortMode = mode);
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<FileSortDirection>(
                          initialValue: _defaultSortDirection,
                          decoration: const InputDecoration(
                            labelText: '默认排序顺序',
                            helperText: '正序从小到大，倒序从大到小',
                            prefixIcon: Icon(Icons.swap_vert),
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final direction in FileSortDirection.values)
                              DropdownMenuItem<FileSortDirection>(
                                value: direction,
                                child: Text(direction.label),
                              ),
                          ],
                          onChanged: (direction) {
                            if (direction != null) {
                              setState(() => _defaultSortDirection = direction);
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        const Divider(),
                        Text(
                          'WebDAV 连接（登录信息）',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        TextFormField(
                          controller: _serverUrlController,
                          contextMenuBuilder: buildClipboardHistoryMenu,
                          decoration: const InputDecoration(
                            labelText: '服务器地址',
                            hintText: 'http://192.168.2.124:5244/dav',
                            prefixIcon: Icon(Icons.link),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _serverUsernameController,
                          contextMenuBuilder: buildClipboardHistoryMenu,
                          decoration: const InputDecoration(
                            labelText: '用户名',
                            prefixIcon: Icon(Icons.person_outline),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _serverPasswordController,
                          obscureText: true,
                          contextMenuBuilder: buildClipboardHistoryMenu,
                          decoration: const InputDecoration(
                            labelText: '密码',
                            helperText: '填写完整连接信息并保存后，下次启动将自动连接服务器（无需登录页）',
                            prefixIcon: Icon(Icons.lock_outline),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('自动注入匹配的外挂字幕'),
                          subtitle: const Text(
                            '播放视频或 STRM 时，将同级目录中名称匹配的字幕加入播放器字幕轨道',
                          ),
                          value: _subtitleInjectionEnabled,
                          onChanged: (v) {
                            setState(() {
                              _subtitleInjectionEnabled = v;
                            });
                          },
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('自动选择已注入的外挂字幕'),
                          subtitle: const Text(
                            '开启后自动切换到外挂字幕；关闭时保留播放器原有的内封字幕选择',
                          ),
                          value:
                              _subtitleInjectionEnabled &&
                              _subtitleAutoSelectEnabled,
                          onChanged: !_subtitleInjectionEnabled
                              ? null
                              : (v) => setState(
                                  () => _subtitleAutoSelectEnabled = v,
                                ),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('自动续播'),
                          subtitle: const Text('有播放进度时传入 --start 参数'),
                          value: _resumeEnabled,
                          onChanged: (v) => setState(() => _resumeEnabled = v),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_outlined),
                          label: Text(_saving ? '保存中…' : '保存配置'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
