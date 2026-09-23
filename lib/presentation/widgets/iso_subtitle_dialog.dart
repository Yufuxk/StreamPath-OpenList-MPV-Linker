import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

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
    this.embedded = false,
    this.onSavingChanged,
  });
  final IsoSubtitleContext subtitles;
  final IsoSubtitleSession? session;
  final List<Map<String, dynamic>> titles;
  final bool embedded;
  final ValueChanged<bool>? onSavingChanged;
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
    widget.onSavingChanged?.call(true);
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
      if (mounted) {
        setState(() => _saving = false);
        widget.onSavingChanged?.call(false);
      }
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
    final content = _content();
    if (widget.embedded) return content;
    return AlertDialog(
      title: const AppText('蓝光外挂字幕'),
      content: SizedBox(width: 680, height: 430, child: content),
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

  Widget _content() {
    final subtitles = widget.subtitles;
    final labels = _candidateLabels();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppText('自动建议按现有规则匹配；手动选择会覆盖建议。'),
        const SizedBox(height: 12),
        if (widget.session != null &&
            (_snapshot == null || _snapshot!['current'] == ''))
          const AppText('当前节目尚不可识别或正在菜单中，自动外挂暂停。'),
        if (subtitles.changed) const AppText('蓝光内容已变化，旧绑定暂停应用；请重新确认。'),
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
          child: ListView.separated(
            padding: const EdgeInsets.only(right: 20),
            itemCount: _titles.length,
            itemBuilder: (_, index) => _row(_titles[index], labels),
            separatorBuilder: (_, _) => const Divider(height: 1),
          ),
        ),
      ],
    );
  }

  Map<String, String> _candidateLabels() {
    final candidates = {
      for (final candidate in widget.subtitles.candidates)
        candidate.path: candidate,
    }.values;
    final counts = <String, int>{};
    for (final candidate in candidates) {
      counts.update(candidate.name, (count) => count + 1, ifAbsent: () => 1);
    }
    final baseLabels = <String, String>{};
    final labelCounts = <String, int>{};
    for (final candidate in candidates) {
      final folder = p.posix.basename(p.posix.dirname(candidate.path));
      final label = counts[candidate.name] == 1
          ? candidate.name
          : '${candidate.name} · ${folder == '.' ? context.l10n.text('根目录') : folder}';
      baseLabels[candidate.path] = label;
      labelCounts.update(label, (count) => count + 1, ifAbsent: () => 1);
    }
    final positions = <String, int>{};
    return {
      for (final entry in baseLabels.entries)
        entry.key: labelCounts[entry.value] == 1
            ? entry.value
            : '${entry.value} (${positions.update(entry.value, (index) => index + 1, ifAbsent: () => 1)})',
    };
  }

  static String _duration(int seconds) {
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final remaining = duration.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$remaining' : '$minutes:$remaining';
  }

  Widget _row(Map<String, dynamic> title, Map<String, String> labels) {
    final id = title['id'] as String;
    final subtitles = widget.subtitles;
    final binding = subtitles.changed
        ? ''
        : subtitles.bindings.containsKey(id)
        ? (subtitles.bindings[id] ?? '-')
        : '';
    final selected = binding == '-' || labels.containsKey(binding)
        ? binding
        : '';
    final seconds = (title['duration'] as num?)?.toInt() ?? 0;
    final suggestion = subtitles.suggestionFor(
      id,
      subtitles.titleCatalog.isEmpty ? _titles : subtitles.titleCatalog,
    );
    final automaticLabel =
        '${context.l10n.text('自动建议')}：${suggestion == null ? context.l10n.text('未绑定') : labels[suggestion] ?? p.posix.basename(suggestion)}';
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_snapshot?['current'] == id) ...[
                Icon(Icons.play_arrow, size: 18, color: scheme.primary),
                const SizedBox(width: 4),
              ],
              Text('$id.mpls', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              Text(
                _duration(seconds),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  key: ValueKey('iso-subtitle-$id'),
                  isExpanded: true,
                  dropdownColor: scheme.surface.withValues(alpha: 1),
                  menuMaxHeight: 320,
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
                        automaticLabel,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const DropdownMenuItem(
                      value: '-',
                      child: AppText('不使用外挂字幕'),
                    ),
                    for (final entry in labels.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(
                          entry.value,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
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
