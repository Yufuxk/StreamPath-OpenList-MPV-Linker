import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

import '../../core/errors/app_exception.dart';
import '../../domain/services/iso_subtitle_service.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';

class IsoSubtitleDialog extends StatefulWidget {
  const IsoSubtitleDialog({
    super.key,
    required this.subtitles,
    this.session,
    this.titles = const [],
  });
  final IsoSubtitleContext subtitles;
  final IsoSubtitleSession? session;
  final List<Map<String, dynamic>> titles;
  @override
  State<IsoSubtitleDialog> createState() => _IsoSubtitleDialogState();
}

class _IsoSubtitleDialogState extends State<IsoSubtitleDialog> {
  Timer? _timer;
  bool _refreshing = false, _saving = false;
  Map<String, dynamic>? _snapshot;
  String? _message;
  List<Map<String, dynamic>> _titles = [];

  @override
  void initState() {
    super.initState();
    _titles = List.of(widget.titles);
    if (widget.session != null) {
      unawaited(_refresh());
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing || _saving) return;
    _refreshing = true;
    try {
      final snapshot = await widget.session?.snapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        final titles = snapshot?['titles'];
        if (titles is List && titles.isNotEmpty) {
          final unique = <String, Map<String, dynamic>>{};
          for (final raw in titles.whereType<Map>()) {
            if (raw['id'] is String) {
              unique[raw['id']] = Map<String, dynamic>.from(raw);
            }
          }
          _titles = unique.values.toList();
        }
      });
    } on StateError {
      if (mounted) setState(() => _snapshot = null);
    } on TimeoutException {
      if (mounted) setState(() => _snapshot = null);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _bind(String id, String value) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    final snapshot = _snapshot;
    try {
      await widget.subtitles.bind(
        id,
        value == '-' || value.isEmpty ? null : value,
        automatic: value.isEmpty,
      );
      final applied =
          widget.session != null &&
          snapshot != null &&
          await widget.session!.update(snapshot);
      if (mounted) {
        setState(
          () => _message = widget.session == null
              ? '字幕绑定已保存'
              : applied
              ? '字幕绑定已保存并应用'
              : '字幕绑定已保存；节目已变化，请刷新后重试应用',
        );
      }
    } on FileSystemException {
      if (mounted) setState(() => _message = '字幕绑定保存失败');
    } on FormatException {
      if (mounted) setState(() => _message = '字幕绑定文件不可用，原文件未覆盖');
    } on AppException {
      if (mounted) setState(() => _message = '字幕资源准备失败，视频继续播放');
    } on StateError {
      if (mounted) setState(() => _message = '字幕绑定已保存；播放器暂不可用');
    } on TimeoutException {
      if (mounted) setState(() => _message = '字幕绑定已保存；播放器暂不可用');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    await _refresh();
  }

  Future<void> _retry() async {
    if (_snapshot == null || widget.session == null) return;
    setState(() => _saving = true);
    try {
      final applied = await widget.session!.update(_snapshot!);
      if (mounted) {
        setState(
          () => _message = applied ? '字幕绑定已保存并应用' : '字幕绑定已保存；节目已变化，请刷新后重试应用',
        );
      }
    } on FileSystemException {
      if (mounted) setState(() => _message = '字幕资源准备失败，视频继续播放');
    } on AppException {
      if (mounted) setState(() => _message = '字幕资源准备失败，视频继续播放');
    } on StateError {
      if (mounted) setState(() => _message = '字幕绑定已保存；播放器暂不可用');
    } on TimeoutException {
      if (mounted) setState(() => _message = '字幕绑定已保存；播放器暂不可用');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitles = widget.subtitles;
    return AlertDialog(
      title: const AppText('ISO 外挂字幕'),
      content: SizedBox(
        width: 680,
        height: 430,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppText('按时长、集数、名称、语言和格式综合评分；明确 MPLS 和手动绑定优先。'),
            if (widget.session != null &&
                (_snapshot == null || _snapshot!['current'] == ''))
              const AppText('当前节目尚不可识别或正在菜单中，自动外挂暂停。'),
            if (subtitles.changed) const AppText('ISO 信息已变化，旧绑定暂停应用；请重新确认。'),
            if (subtitles.issues.isNotEmpty || _snapshot?['status'] == 'failed')
              const AppText('部分字幕或字体资源不可用，视频播放不受影响。'),
            if (!subtitles.writable) const AppText('字幕绑定文件不可用，原文件未覆盖'),
            if (_message != null) AppText(_message!),
            if (_titles.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: AppText('等待播放器提供节目列表。'),
              ),
            Expanded(
              child: ListView(
                children: [for (final title in _titles) _row(title)],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.session != null)
          TextButton(
            onPressed: _saving ? null : _retry,
            child: const AppText('重试应用字幕'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const AppText('关闭'),
        ),
      ],
    );
  }

  Widget _row(Map<String, dynamic> title) {
    final id = title['id'] as String;
    final subtitles = widget.subtitles;
    final binding = subtitles.changed
        ? ''
        : subtitles.bindings.containsKey(id)
        ? (subtitles.bindings[id] ?? '-')
        : '';
    final paths = subtitles.candidates.map((c) => c.path).toSet();
    final selected = binding == '-' || paths.contains(binding) ? binding : '';
    final seconds = (title['duration'] as num?)?.toInt() ?? 0;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        '${_snapshot?['current'] == id ? '▶ ' : ''}$id.mpls · ${Duration(seconds: seconds)}',
      ),
      subtitle: DropdownButton<String>(
        key: ValueKey('iso-subtitle-$id'),
        isExpanded: true,
        value: selected,
        onChanged: _saving || !subtitles.writable
            ? null
            : (value) {
                if (value != null) unawaited(_bind(id, value));
              },
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(
              '${context.l10n.text('自动建议')}：${subtitles.suggestionFor(id, subtitles.titleCatalog.isEmpty ? _titles : subtitles.titleCatalog) ?? context.l10n.text('未绑定')}',
            ),
          ),
          const DropdownMenuItem(value: '-', child: AppText('不使用外挂字幕')),
          for (final path in paths)
            DropdownMenuItem(
              value: path,
              child: Text(path, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
  }
}
