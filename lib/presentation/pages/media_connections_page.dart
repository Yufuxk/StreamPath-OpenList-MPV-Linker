import '../widgets/sp_menu.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/media_connection.dart';
import '../../data/models/media_source.dart';
import '../../domain/services/media_server_api.dart';
import '../../domain/services/native_storage_source.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../controllers/film_catalog_controller.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/directory_scroll_view.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/sp_dialog.dart';
import '../widgets/sp_icons.dart';
import '../widgets/sp_notice.dart';
import 'browser_page.dart';

class MediaConnectionsPage extends StatefulWidget {
  const MediaConnectionsPage({
    super.key,
    this.servers = false,
    this.embedded = false,
    this.management = false,
    this.onAddWebDav,
    this.beforeConnections,
  });
  final bool servers, embedded, management;
  final VoidCallback? onAddWebDav;
  final Widget? beforeConnections;
  @override
  State<MediaConnectionsPage> createState() => _MediaConnectionsPageState();
}

class _MediaConnectionsPageState extends State<MediaConnectionsPage> {
  String? _error;
  final _busy = <String>{};
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await context.read<AppState>().getMediaConnections();
    } on FileSystemException {
      if (mounted) setState(() => _error = 'connectionConfigFailed');
    } on FormatException {
      if (mounted) setState(() => _error = 'connectionConfigFailed');
    } on FilmCatalogException catch (error) {
      if (mounted) setState(() => _error = error.code);
    }
  }

  Future<void> _run(String id, Future<void> Function() action) async {
    if (!_busy.add(id)) return;
    setState(() => _error = null);
    try {
      await action();
    } on FilmCatalogException catch (error) {
      _error = error.code;
    } on FileSystemException {
      _error = 'connectionConfigFailed';
    } finally {
      _busy.remove(id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _edit([MediaConnection? config]) async {
    await showGlassDialog<bool>(
      context: context,
      builder: (_) =>
          _ConnectionEditor(servers: widget.servers, config: config),
    );
  }

  Future<void> _add(BuildContext buttonContext) async {
    if (widget.onAddWebDav == null) {
      await _edit();
      return;
    }
    final box = buttonContext.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final selected = await showSPMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(
            box.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'webdav', child: AppText('添加 WebDAV 挂载')),
        PopupMenuItem(value: 'native', child: Text('SMB / FTP / NFS')),
      ],
    );
    if (!mounted) return;
    if (selected == 'webdav') widget.onAddWebDav!();
    if (selected == 'native') await _edit();
  }

  Future<void> _open(MediaConnection config) => _run(config.id, () async {
    final app = context.read<AppState>();
    await app.mountMediaConnection(config.id);
    if (!mounted) return;
    if (config.kind.isNativeStorage) {
      final source = app.nativeSource(config.id)!;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BrowserPage(
            webDavSource: source.service,
            directorySource: source,
          ),
        ),
      );
    }
  });
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final rows = app.mediaConnections
        .where((row) => row.kind.isMediaServer == widget.servers)
        .toList();
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Builder(
            builder: (buttonContext) => FilledButton.icon(
              onPressed: () => _add(buttonContext),
              icon: const Icon(SPIcons.add),
              label: AppText(widget.servers ? '添加媒体服务器' : '添加网络存储'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (widget.beforeConnections != null) widget.beforeConnections!,
        for (final row in rows)
          ListTile(
            leading: Icon(widget.servers ? SPIcons.video : SPIcons.cloud),
            title: Text('${row.name} · ${row.kind.name.toUpperCase()}'),
            subtitle: Text(row.url),
            onTap: widget.servers || !row.enabled || _busy.contains(row.id)
                ? null
                : () => _open(row),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_busy.contains(row.id))
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (widget.management)
                  Switch(
                    value: row.enabled,
                    onChanged: _busy.contains(row.id)
                        ? null
                        : (value) => _run(
                            row.id,
                            () => app.saveMediaConnection(
                              MediaConnection.fromJson({
                                ...row.toJson(),
                                'enabled': value,
                              }),
                            ),
                          ),
                  ),
                IconButton(
                  tooltip: context.l10n.text('验证连接'),
                  icon: const Icon(SPIcons.refresh),
                  onPressed: _busy.contains(row.id)
                      ? null
                      : () => _run(row.id, () async {
                          await app.mountMediaConnection(row.id);
                          if (row.kind.isMediaServer) {
                            await app.serverApi(row.id)!.verify();
                          } else {
                            await app
                                .nativeSource(row.id)!
                                .fetchDirectory('', forceRefresh: true);
                          }
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SPNotice(content: AppText('连接成功')),
                            );
                          }
                        }),
                ),
                IconButton(
                  tooltip: context.l10n.text('编辑'),
                  icon: const Icon(SPIcons.edit),
                  onPressed: () => _edit(row),
                ),
                if (widget.management)
                  IconButton(
                    tooltip: context.l10n.text('移除'),
                    icon: const Icon(SPIcons.delete),
                    onPressed: () =>
                        _run(row.id, () => app.removeMediaConnection(row.id)),
                  ),
              ],
            ),
          ),
        if (_error != null)
          AppText(
            filmCatalogErrorText(_error!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
    if (widget.embedded) return content;
    return DirectoryScrollView(
      builder: (controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.all(20),
        children: [content],
      ),
    );
  }
}

class _ConnectionEditor extends StatefulWidget {
  const _ConnectionEditor({required this.servers, this.config});
  final bool servers;
  final MediaConnection? config;
  @override
  State<_ConnectionEditor> createState() => _ConnectionEditorState();
}

class _ConnectionEditorState extends State<_ConnectionEditor> {
  final _name = TextEditingController(),
      _url = TextEditingController(),
      _user = TextEditingController(),
      _password = TextEditingController(),
      _domain = TextEditingController(),
      _uid = TextEditingController(),
      _gid = TextEditingController();
  late MediaSourceKind _kind;
  bool _readOnly = false,
      _writeBack = false,
      _local = false,
      _passive = true,
      _saving = false;
  int _nfsVersion = 3;
  String? _error;
  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _kind =
        c?.kind ??
        (widget.servers ? MediaSourceKind.jellyfin : MediaSourceKind.smb);
    _name.text = c?.name ?? '';
    _url.text = c?.url ?? '';
    _user.text = c?.username ?? '';
    _domain.text = c?.domain ?? '';
    _uid.text = '${c?.uid ?? 65534}';
    _gid.text = '${c?.gid ?? 65534}';
    _readOnly = c?.readOnly ?? false;
    _writeBack = c?.writeBack ?? false;
    _local = c?.localMetadata ?? false;
    _passive = c?.passive ?? true;
    _nfsVersion = c?.nfsVersion ?? 3;
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _user, _password, _domain, _uid, _gid]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final app = context.read<AppState>();
    try {
      final c = MediaConnection(
        id: widget.config?.id ?? MediaConnection.newId(_kind),
        kind: _kind,
        name: _name.text.trim(),
        url: _url.text.trim(),
        username: _user.text.trim(),
        domain: _domain.text.trim(),
        uid: int.parse(_uid.text),
        gid: int.parse(_gid.text),
        nfsVersion: _nfsVersion,
        passive: _passive,
        enabled: widget.config?.enabled ?? true,
        readOnly: _readOnly,
        writeBack: _kind != MediaSourceKind.ftp && !_readOnly && _writeBack,
        localMetadata: _local,
      );
      c.validate();
      final saved = widget.config == null
          ? <String, dynamic>{}
          : await (await app.getMediaConnections()).secrets(c.id);
      final password = _password.text.isEmpty
          ? saved['password'] as String? ?? ''
          : _password.text;
      Map<String, dynamic> secrets;
      if (_kind.isMediaServer) {
        final api = mediaServerApi(c);
        try {
          secrets = await api.authenticate(password);
        } finally {
          api.close();
        }
      } else {
        final source = await NativeStorageSource.open(c, password);
        try {
          await source.fetchDirectory('', forceRefresh: true);
        } finally {
          await source.close();
        }
        secrets = {'password': password};
      }
      await app.saveMediaConnection(c, secrets: secrets);
      if (c.enabled) await app.mountMediaConnection(c.id);
      if (mounted) Navigator.of(context).pop(true);
    } on FormatException {
      _error = 'connectionConfigFailed';
    } on FilmCatalogException catch (error) {
      _error = error.code;
    } on FileSystemException {
      _error = 'connectionConfigFailed';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    bool obscure = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      obscureText: obscure,
      decoration: InputDecoration(label: AppText(label)),
    ),
  );
  @override
  Widget build(BuildContext context) => SPDialog(
    title: AppText(widget.config == null ? '添加来源' : '编辑来源'),
    content: SizedBox(
      width: 520,
      child: DirectoryScrollView(
        builder: (controller) => SingleChildScrollView(
          controller: controller,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SPDropdownButtonFormField<MediaSourceKind>(
                initialValue: _kind,
                isExpanded: true,
                dropdownColor: AppTheme.dropdownMenuColor(Theme.of(context)),
                borderRadius: AppTheme.dropdownBorderRadius,
                items: [
                  for (final kind in MediaSourceKind.values.where(
                    (k) => widget.servers ? k.isMediaServer : k.isNativeStorage,
                  ))
                    DropdownMenuItem(
                      value: kind,
                      child: Text(kind.name.toUpperCase()),
                    ),
                ],
                onChanged: _saving || widget.config != null
                    ? null
                    : (value) => setState(() => _kind = value!),
              ),
              const SizedBox(height: 12),
              _field(_name, '来源名称'),
              _field(_url, '来源地址'),
              if (_kind != MediaSourceKind.nfs) ...[
                _field(_user, '用户名'),
                _field(_password, '密码', obscure: true),
              ],
              if (_kind == MediaSourceKind.smb) _field(_domain, '域（可选）'),
              if (_kind == MediaSourceKind.nfs) ...[
                _field(_uid, 'UID'),
                _field(_gid, 'GID'),
                SPDropdownButtonFormField<int>(
                  initialValue: _nfsVersion,
                  dropdownColor: AppTheme.dropdownMenuColor(Theme.of(context)),
                  borderRadius: AppTheme.dropdownBorderRadius,
                  items: [
                    for (final v in [3, 4])
                      DropdownMenuItem(value: v, child: Text('NFS v$v')),
                  ],
                  onChanged: (v) => setState(() => _nfsVersion = v!),
                ),
              ],
              if (_kind == MediaSourceKind.ftp)
                SwitchListTile(
                  title: const AppText('被动模式'),
                  value: _passive,
                  onChanged: (v) => setState(() => _passive = v),
                ),
              if (!_kind.isMediaServer) ...[
                SwitchListTile(
                  title: const AppText('只读来源'),
                  value: _readOnly,
                  onChanged: (v) => setState(() {
                    _readOnly = v;
                    if (v) _writeBack = false;
                  }),
                ),
                if (_kind == MediaSourceKind.ftp)
                  const AppText('该来源不支持安全创建文件，已禁用自动写回'),
                SwitchListTile(
                  title: const AppText('允许写回缺少的 NFO 和图片'),
                  value: _kind != MediaSourceKind.ftp && _writeBack,
                  onChanged: _readOnly || _kind == MediaSourceKind.ftp
                      ? null
                      : (v) => setState(() => _writeBack = v),
                ),
                SwitchListTile(
                  title: const AppText('本地元数据模式'),
                  value: _local,
                  onChanged: (v) => setState(() => _local = v),
                ),
              ],
              if (_error != null)
                AppText(
                  filmCatalogErrorText(_error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
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
        onPressed: _saving ? null : _save,
        child: AppText(_saving ? '正在验证…' : '验证并保存'),
      ),
    ],
  );
}
