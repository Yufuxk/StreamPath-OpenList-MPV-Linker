import 'package:flutter/material.dart';

import '../localization/app_text.dart';

import '../../data/models/media_directory_entry.dart';
import '../theme/glass_tokens.dart';
import 'glass_surface.dart';

const double _metadataBreakpoint = 680;
const double _sizeColumnWidth = 96;
const double _modifiedColumnWidth = 152;
const double _wideTileHeight = 56;
const double _leadingColumnWidth = 40;
const double _leadingGap = 16;
const double _trailingGap = 16;
const double _trailingColumnWidth = 36;

/// 为文件条目的 Ink 悬浮反馈提供同层绘制表面。
class FileListSurface extends StatelessWidget {
  const FileListSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      level: GlassSurfaceLevel.content,
      automaticBorder: false,
      child: child,
    );
  }
}

/// 目录列表表头；窄窗口下元数据改在条目副标题显示，因此隐藏表头。
class FileListHeader extends StatelessWidget {
  const FileListHeader({super.key, this.metadataColumnLabel = '修改时间'});

  final String metadataColumnLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.35,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _metadataBreakpoint) {
          return const SizedBox.shrink();
        }
        return Container(
          key: const Key('file-list-header'),
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              SizedBox(
                width: _leadingColumnWidth,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AppText('名称', style: style),
                ),
              ),
              const SizedBox(width: _leadingGap),
              const Spacer(),
              SizedBox(
                width: _sizeColumnWidth,
                child: AppText('大小', textAlign: TextAlign.right, style: style),
              ),
              const SizedBox(width: 24),
              SizedBox(
                width: _modifiedColumnWidth,
                child: AppText(
                  metadataColumnLabel,
                  textAlign: TextAlign.right,
                  style: style,
                ),
              ),
              const SizedBox(width: _trailingGap),
              const SizedBox(width: _trailingColumnWidth),
            ],
          ),
        );
      },
    );
  }
}

/// 文件列表项（虚拟列表单元）。
///
/// 轻量 StatelessWidget：万级条目下 Flutter 仅构建可视区，
/// 配合 `const` 构造与无动画实现流畅滚动。
class FileTile extends StatelessWidget {
  const FileTile({
    super.key,
    required this.file,
    this.onTap,
    this.trailing,
    this.subtitle,
    this.metadataColumnText,
  });

  final MediaDirectoryEntry file;

  /// 单击回调（目录进入 / 视频或音频播放 / 「返回上级」）。
  final VoidCallback? onTap;

  final Widget? trailing;

  /// 可选的来源路径等补充信息。
  final String? subtitle;

  /// 宽窗口右侧元数据列的替代文本；未提供时显示修改时间。
  final String? metadataColumnText;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showColumns = constraints.maxWidth >= _metadataBreakpoint;
        if (showColumns) return _buildWideTile(context);

        final scheme = Theme.of(context).colorScheme;
        if (file.isSelfEntry) {
          // 窄窗口保留原来的两行「返回上级」布局。
          return ListTile(
            onTap: onTap,
            hoverColor: Theme.of(context).hoverColor,
            leading: Icon(Icons.arrow_upward, color: scheme.primary, size: 28),
            title: AppText(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15),
            ),
            subtitle: const AppText('返回上级目录'),
            trailing: trailing,
            dense: true,
          );
        }
        return ListTile(
          onTap: onTap,
          hoverColor: Theme.of(context).hoverColor,
          leading: Icon(
            _iconFor(file),
            color: _colorFor(file, scheme),
            size: 28,
          ),
          title: AppText(
            file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
          subtitle: _buildCompactMetadata(),
          trailing: trailing,
          dense: true,
        );
      },
    );
  }

  Widget _buildWideTile(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final metadataStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final leading = file.isSelfEntry
        ? Icon(Icons.arrow_upward, color: scheme.primary, size: 28)
        : Icon(_iconFor(file), color: _colorFor(file, scheme), size: 28);
    return SizedBox(
      key: ValueKey<String>('wide-file-tile-${file.entryKey}'),
      height: _wideTileHeight,
      child: InkWell(
        onTap: onTap,
        hoverColor: Theme.of(context).hoverColor,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: _leadingColumnWidth,
                child: Align(alignment: Alignment.centerLeft, child: leading),
              ),
              const SizedBox(width: _leadingGap),
              Expanded(child: _buildWideName(context)),
              SizedBox(
                width: _sizeColumnWidth,
                child: AppText(
                  file.isDirectory ? '-' : file.sizeLabel,
                  maxLines: 1,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: metadataStyle,
                ),
              ),
              const SizedBox(width: 24),
              SizedBox(
                width: _modifiedColumnWidth,
                child: AppText(
                  metadataColumnText ??
                      (file.isSelfEntry || file.modified == null
                          ? ''
                          : _formatDate(file.modified!)),
                  maxLines: 1,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: metadataStyle,
                ),
              ),
              const SizedBox(width: _trailingGap),
              SizedBox(
                width: _trailingColumnWidth,
                height: _trailingColumnWidth,
                child: trailing == null ? null : Center(child: trailing),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWideName(BuildContext context) {
    if (!file.isSelfEntry && subtitle == null) {
      return AppText(
        file.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          file.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
        AppText(
          file.isSelfEntry ? '返回上级目录' : subtitle!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget? _buildCompactMetadata() {
    final parts = <String>[
      ?subtitle,
      if (!file.isDirectory) file.sizeLabel,
      if (file.modified != null) _formatDate(file.modified!),
    ];
    return parts.isEmpty
        ? null
        : AppText(parts.join(' · '), style: const TextStyle(fontSize: 12));
  }

  static IconData _iconFor(MediaDirectoryEntry f) {
    if (f.isDirectory) return Icons.folder_outlined;
    if (f.isIso) return Icons.album_outlined;
    if (f.isAudio) return Icons.audiotrack_outlined;
    if (f.isPlayable) return Icons.movie_outlined;
    if (f.isLyrics) return Icons.lyrics_outlined;
    if (f.isSubtitle) return Icons.subtitles_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static Color _colorFor(MediaDirectoryEntry f, ColorScheme scheme) {
    if (f.isDirectory) return scheme.primary;
    if (f.isIso) return scheme.tertiary;
    if (f.isAudio || f.isLyrics) return scheme.secondary;
    if (f.isPlayable) return scheme.tertiary;
    if (f.isSubtitle) return scheme.primary;
    return scheme.outline;
  }

  static String _formatDate(DateTime d) {
    final local = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}
