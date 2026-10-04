import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/server_profile.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/glass_tokens.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mounted_playback_bars.dart';
import '../widgets/sp_icons.dart';
import '../widgets/sp_notice.dart';
import 'browser_page.dart';

class NetworkStoragePage extends StatefulWidget {
  const NetworkStoragePage({super.key, this.embedded = false});
  final bool embedded;

  @override
  State<NetworkStoragePage> createState() => _NetworkStoragePageState();
}

class _NetworkStoragePageState extends State<NetworkStoragePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final Set<String> _busy = {};
  int _barsRevision = 0;

  @override
  void initState() {
    super.initState();
    unawaited(context.read<AppState>().restoreMountedProfiles());
  }

  Future<void> _open(String id) async {
    if (!_busy.add(id)) {
      return;
    }
    setState(() {});
    try {
      await context.read<AppState>().activateMountedProfile(id);
      if (!mounted) return;
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const BrowserPage()));
      if (mounted) setState(() => _barsRevision++);
    } on AppException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SPNotice(content: AppText(error.message)));
      }
    } finally {
      _busy.remove(id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final app = context.watch<AppState>();
    final config = app.configStore.current;
    final profiles = <ServerProfile>[
      for (final id in config.mountedProfileIds)
        if (config.profiles.where((item) => item.profileId == id).firstOrNull
            case final ServerProfile profile)
          profile,
    ];
    final content = profiles.isEmpty
        ? const Center(child: AppText('在文件夹管理中添加服务器'))
        : GlassSurface(
            level: GlassSurfaceLevel.content,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            automaticBorder: false,
            showShadow: false,
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: profiles.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final profile = profiles[index];
                final busy = _busy.contains(profile.profileId);
                return ListTile(
                  key: ValueKey('network-profile-${profile.profileId}'),
                  leading: const Icon(SPIcons.cloud, size: 32),
                  title: AppText(profile.name),
                  subtitle: AppText(
                    app.isProfileConnected(profile.profileId)
                        ? profile.serverUrl
                        : busy
                        ? '正在连接…'
                        : app.mountError(profile.profileId) == null
                        ? '点击连接'
                        : '连接失败，点击重试',
                  ),
                  onTap: busy ? null : () => _open(profile.profileId),
                );
              },
            ),
          );
    final bars = MountedPlaybackBars(
      key: ValueKey('$_barsRevision-${config.mountedProfileIds.join('|')}'),
      network: true,
    );
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [content, bars],
      );
    }
    return Scaffold(
      appBar: AppBar(toolbarHeight: 48, title: const AppText('网络文件夹')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: content,
      ),
      bottomNavigationBar: bars,
    );
  }
}
