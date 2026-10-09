import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../domain/services/app_update_service.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import 'settings_group_card.dart';
import 'sp_controls.dart';
import 'sp_icons.dart';
import 'sp_notice.dart';

class AppUpdateSettingsCard extends StatelessWidget {
  const AppUpdateSettingsCard({super.key, required this.service});
  final AppUpdateService service;

  Future<void> _restart(BuildContext context) async {
    try {
      await service.restartToUpdate(
        busyWithUserData: context.read<AppState>().updateBlocked,
      );
    } on AppUpdateBlocked {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SPNotice(content: AppText('请先结束播放、扫描或导入，再重启更新')));
      }
    } on FileSystemException {
      if (context.mounted) _showFailure(context);
    } on ProcessException {
      if (context.mounted) _showFailure(context);
    } on PlatformException {
      if (context.mounted) _showFailure(context);
    }
  }

  void _showFailure(BuildContext context) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SPNotice(content: AppText('无法启动更新，请重试')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final statusText = switch (service.status) {
        AppUpdateStatus.idle => '启动后自动检查并下载，重启更新需手动确认',
        AppUpdateStatus.checking => '正在检查更新…',
        AppUpdateStatus.downloading => '正在后台下载更新…',
        AppUpdateStatus.ready => '更新已下载，重启后安装',
        AppUpdateStatus.installing => '正在保存状态并准备更新…',
        AppUpdateStatus.current => '当前已是最新版本',
        AppUpdateStatus.unavailable => '此 Release 缺少匹配的安全更新包或发布清单',
        AppUpdateStatus.failed => '更新检查或下载失败，可重试',
      };
      return SettingsGroupCard(
        key: const Key('app-update-settings'),
        icon: SPIcons.download,
        title: '软件更新',
        description: '更新保留配置、缓存和播放记录；播放时可下载，结束后再安装。',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.format('当前版本：{version}', {
                'version': service.version,
              }),
            ),
            const SizedBox(height: 8),
            AppText(statusText),
            if (service.previousUpdateFailed) ...[
              const SizedBox(height: 8),
              const AppText('上次更新未完成，旧程序和数据已保留'),
            ],
            if (service.asset != null) ...[
              const SizedBox(height: 8),
              Text(
                context.l10n.format('可用版本：{version}', {
                  'version': service.asset!.version,
                }),
              ),
            ],
            if (service.status == AppUpdateStatus.downloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: service.progress),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SPButton(
                  controlKey: const Key('check-app-update'),
                  onPressed: service.busy ? null : service.check,
                  label: const AppText('检查更新'),
                ),
                if (service.status == AppUpdateStatus.ready)
                  SPButton(
                    controlKey: const Key('restart-app-update'),
                    kind: SPButtonKind.primary,
                    onPressed: () => _restart(context),
                    label: const AppText('重启更新'),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
