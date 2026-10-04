import 'package:flutter/material.dart';
import '../../data/models/video_queue.dart';
import '../localization/app_text.dart';
import 'glass_dialog.dart';
import 'sp_dialog.dart';

Future<VideoQueueVersion?> showVideoVersionDialog(
  BuildContext context,
  VideoQueueItem item,
) => showGlassDialog<VideoQueueVersion>(
  context: context,
  builder: (ctx) => SPDialog(
    title: const AppText('选择播放版本'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final version in item.versions)
              ListTile(
                title: Text(version.name),
                onTap: () => Navigator.of(ctx).pop(version),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(),
        child: const AppText('取消'),
      ),
    ],
  ),
);
