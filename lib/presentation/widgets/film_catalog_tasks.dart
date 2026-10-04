import 'package:flutter/material.dart';

import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import 'settings_group_card.dart';
import 'sp_icons.dart';

/// 扫描和刮削各自显示进度与控制，不随另一项任务结束而隐藏。
class FilmCatalogTasks extends StatelessWidget {
  const FilmCatalogTasks({
    super.key,
    required this.catalog,
    this.panel = false,
  });
  final FilmCatalogController catalog;
  final bool panel;

  @override
  Widget build(BuildContext context) {
    final c = catalog;
    final tasks = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (c.busy) ...[
          const LinearProgressIndicator(),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                c.progress == null
                    ? context.l10n.text('正在扫描…')
                    : context.l10n.format(
                        '扫描：已读取 {dirs} 个目录 · 发现 {files} 个文件 · {path}',
                        {
                          'dirs': c.progress!.directories,
                          'files': c.progress!.files,
                          'path': c.progress!.path,
                        },
                      ),
              ),
              TextButton(
                onPressed: c.cancelling ? null : c.cancel,
                child: AppText(c.cancelling ? '正在取消…' : '取消扫描'),
              ),
            ],
          ),
        ],
        if (c.scraping) ...[
          if (!c.scrapePaused) const LinearProgressIndicator(),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppText(c.scrapePaused ? '刮削已暂停' : '正在刮削…'),
              Text(
                context.l10n
                    .format('已处理 {processed}/{total} 个文件 · 已匹配 {matched} 个', {
                      'processed': c.scrapeProcessed,
                      'total': c.scrapeTotal,
                      'matched': c.scrapedCount,
                    }),
              ),
              TextButton(
                onPressed: c.toggleScraping,
                child: AppText(c.scrapePaused ? '继续刮削' : '暂停刮削'),
              ),
            ],
          ),
        ],
        if (c.scrapeError != null)
          AppText(
            filmCatalogErrorText(c.scrapeError!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
    if (!panel) return tasks;
    return SettingsProgressPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                SPIcons.diagnostic,
                color: Theme.of(context).colorScheme.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              const AppText('影视库任务进度'),
            ],
          ),
          const SizedBox(height: 12),
          if (!c.busy && !c.scraping) const AppText('空闲'),
          tasks,
        ],
      ),
    );
  }
}
