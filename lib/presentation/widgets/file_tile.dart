import 'package:flutter/material.dart';

import '../../data/models/web_dav_file.dart';

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
  });

  final WebDavFile file;

  /// 单击回调（目录进入 / 视频播放 / 「返回上级」）。
  final VoidCallback? onTap;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (file.isSelfEntry) {
      // 「返回上级」条目：置顶展示，点击返回上级目录。
      return ListTile(
        onTap: onTap,
        leading: Icon(Icons.arrow_upward,
            color: scheme.primary, size: 28),
        title: Text(
          file.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        subtitle: const Text('返回上级目录'),
        trailing: trailing,
        dense: true,
      );
    }
    return ListTile(
      onTap: onTap,
      leading: Icon(_iconFor(file), color: _colorFor(file, scheme), size: 28),
      title: Text(
        file.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15),
      ),
      subtitle: file.isDirectory
          ? const Text('目录')
          : Text(
              '${file.sizeLabel}'
              '${file.modified != null ? ' · ${_formatDate(file.modified!)}' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
      trailing: trailing,
      dense: true,
    );
  }

  static IconData _iconFor(WebDavFile f) {
    if (f.isDirectory) return Icons.folder_outlined;
    if (f.isPlayable) return Icons.movie_outlined;
    if (f.isSubtitle) return Icons.subtitles_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static Color _colorFor(WebDavFile f, ColorScheme scheme) {
    if (f.isDirectory) return scheme.primary;
    if (f.isPlayable) return Colors.deepOrange;
    if (f.isSubtitle) return Colors.teal;
    return scheme.outline;
  }

  static String _formatDate(DateTime d) {
    final local = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
