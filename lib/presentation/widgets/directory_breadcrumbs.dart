import 'package:flutter/material.dart';

import '../localization/app_text.dart';

/// WebDAV 与本地浏览页共用的可交互面包屑路径。
class DirectoryBreadcrumbs extends StatelessWidget {
  const DirectoryBreadcrumbs({
    super.key,
    required this.crumbs,
    required this.onNavigate,
  });

  final List<String> crumbs;

  /// `-1` 表示根目录，其余值为面包屑下标。
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        TextButton(
          key: const Key('directory-root-breadcrumb'),
          onPressed: crumbs.isEmpty ? null : () => onNavigate(-1),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.only(right: 8),
            minimumSize: const Size(0, 40),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            alignment: Alignment.centerLeft,
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.home_outlined, size: 18),
              SizedBox(width: 6),
              AppText('根目录'),
            ],
          ),
        ),
        for (var index = 0; index < crumbs.length; index++) ...[
          Icon(
            Icons.chevron_right,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          TextButton(
            key: ValueKey<String>('directory-breadcrumb-$index'),
            onPressed: () => onNavigate(index),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: AppText(crumbs[index]),
          ),
        ],
      ],
    ),
  );
}
