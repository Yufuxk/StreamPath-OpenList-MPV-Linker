import 'package:flutter/material.dart';
import 'sp_icons.dart';

import '../localization/app_text.dart';

import '../../data/models/media_directory_entry.dart';
import '../theme/glass_tokens.dart';
import 'glass_surface.dart';
import 'sp_controls.dart';

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
      level: GlassSurfaceLevel.raised,
      automaticBorder: false,
      showShadow: false,
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
    this.folderSize,
    this.selected = false,
  });

  final MediaDirectoryEntry file;

  /// 单击回调（目录进入 / 视频或音频播放 / 「返回上级」）。
  final VoidCallback? onTap;

  final Widget? trailing;

  /// 可选的来源路径等补充信息。
  final String? subtitle;

  /// 宽窗口右侧元数据列的替代文本；未提供时显示修改时间。
  final String? metadataColumnText;
  final Future<int>? folderSize;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showColumns = constraints.maxWidth >= _metadataBreakpoint;
        if (showColumns) return _buildWideTile(context);

        final scheme = Theme.of(context).colorScheme;
        final compactMetadata = _buildCompactMetadata();
        return SPTile(
          onTap: onTap,
          selected: selected,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Icon(
                    file.isSelfEntry ? SPIcons.up : iconFor(file),
                    color: file.isSelfEntry
                        ? scheme.primary
                        : colorFor(file, scheme),
                    size: 32,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: file.isSelfEntry
                              ? FontWeight.normal
                              : FontWeight.w500,
                        ),
                      ),
                      if (file.isSelfEntry)
                        const AppText('返回上级目录')
                      else
                        ?compactMetadata,
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 16), trailing!],
              ],
            ),
          ),
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
        ? Icon(SPIcons.up, color: scheme.primary, size: 32)
        : Icon(iconFor(file), color: colorFor(file, scheme), size: 32);
    return SizedBox(
      key: ValueKey<String>('wide-file-tile-${file.entryKey}'),
      height: _wideTileHeight,
      child: SPTile(
        onTap: onTap,
        selected: selected,
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
                child: folderSize == null
                    ? AppText(
                        file.isDirectory ? '-' : file.sizeLabel,
                        maxLines: 1,
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                        style: metadataStyle,
                      )
                    : FutureBuilder<int>(
                        future: folderSize,
                        builder: (context, snapshot) => AppText(
                          snapshot.hasError
                              ? '—'
                              : snapshot.hasData
                              ? formatBytes(snapshot.data!)
                              : '…',
                          textAlign: TextAlign.right,
                          style: metadataStyle,
                        ),
                      ),
              ),
              const SizedBox(width: 24),
              SizedBox(
                width: _modifiedColumnWidth,
                child: AppText(
                  metadataColumnText ??
                      (file.isSelfEntry || file.modified == null
                          ? ''
                          : formatDate(file.modified!)),
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
      if (file.modified != null) formatDate(file.modified!),
    ];
    if (folderSize == null) {
      return parts.isEmpty
          ? null
          : AppText(parts.join(' · '), style: const TextStyle(fontSize: 12));
    }
    return FutureBuilder<int>(
      future: folderSize,
      builder: (context, snapshot) => AppText(
        [
          if (snapshot.hasError)
            '—'
          else if (snapshot.hasData)
            formatBytes(snapshot.data!)
          else
            '…',
          ...parts,
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  static IconData iconFor(MediaDirectoryEntry f) {
    if (f.isDirectory) return SPIcons.folder;
    if (f.isIso) return SPIcons.disc;
    if (f.isAudio) return SPIcons.music;
    if (f.isPlayable) return SPIcons.video;
    if (f.isLyrics) return SPIcons.lyrics;
    if (f.isSubtitle) return SPIcons.subtitles;
    return SPIcons.document;
  }

  static Color colorFor(MediaDirectoryEntry f, ColorScheme scheme) {
    if (f.isDirectory) return scheme.primary;
    if (f.isIso) return scheme.tertiary;
    if (f.isAudio || f.isLyrics) return scheme.secondary;
    if (f.isPlayable) return scheme.tertiary;
    if (f.isSubtitle) return scheme.primary;
    return scheme.outline;
  }

  static String formatDate(DateTime d) {
    final local = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    if (bytes < 1073741824) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MiB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} GiB';
  }
}
