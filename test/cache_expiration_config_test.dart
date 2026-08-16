import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/constants.dart';
import 'package:streampath/features/cache_expiration/models/cache_expiration_config.dart';
import 'package:streampath/features/cache_expiration/store/cache_expiration_config_store.dart';

void main() {
  late Directory tempDir;
  late String path;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('cache_expiration_config_');
    path =
        '${tempDir.path}${Platform.pathSeparator}${CacheExpirationConfigStore.configFileName}';
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('默认配置与代码安全默认值一致，学习数据没有过期项', () {
    final config = CacheExpirationConfig.defaults();

    expect(config.directoryFreshness, AppConstants.directoryCacheTtl);
    expect(config.directoryRetention, AppConstants.directoryCacheRetention);
    expect(
      config.directoryScrollRetention,
      AppConstants.directoryScrollRetention,
    );
    expect(config.playbackRetention, AppConstants.playbackCacheRetention);
    expect(
      config.mediaMetadataRetention,
      AppConstants.mediaMetadataCacheRetention,
    );
    expect(CacheExpirationConfig.learningAutomaticallyExpires, isFalse);
    expect(config.toJson()['learningRetention'], isNull);
  });

  test('配置文件不存在时创建默认文件并可重新加载', () async {
    final store = CacheExpirationConfigStore.forPath(path);
    await store.ensureDefault();

    expect(File(path).existsSync(), isTrue);
    final loaded = await CacheExpirationConfigStore.forPath(path).load();
    expect(
      loaded.playbackRetentionDays,
      CacheExpirationConfig.defaultPlaybackRetentionDays,
    );
  });

  test('手工配置的合法值生效，越界和非法字段逐项收敛', () async {
    await File(path).writeAsString(
      jsonEncode({
        'directoryFreshnessMinutes': 45,
        'directoryRetentionDays': 99999,
        'directoryScrollRetentionMinutes': 0,
        'playbackRetentionDays': 90,
        'mediaMetadataRetentionDays': 'bad',
      }),
    );

    final loaded = await CacheExpirationConfigStore.forPath(path).load();
    expect(loaded.directoryFreshnessMinutes, 45);
    expect(loaded.directoryRetentionDays, CacheExpirationConfig.maxDays);
    expect(
      loaded.directoryScrollRetentionMinutes,
      CacheExpirationConfig.minMinutes,
    );
    expect(loaded.playbackRetentionDays, 90);
    expect(
      loaded.mediaMetadataRetentionDays,
      CacheExpirationConfig.defaultMediaMetadataRetentionDays,
    );
  });

  test('保存使用临时文件替换并立即更新当前策略', () async {
    final store = CacheExpirationConfigStore.forPath(path);
    const config = CacheExpirationConfig(playbackRetentionDays: 30);

    expect(await store.save(config), isTrue);
    expect(store.current.playbackRetentionDays, 30);
    expect(File('$path.tmp').existsSync(), isFalse);

    const updated = CacheExpirationConfig(playbackRetentionDays: 7);
    expect(await store.save(updated), isTrue, reason: '已有配置必须可被设置页覆盖');
    expect(store.current.playbackRetentionDays, 7);
    expect(
      (await CacheExpirationConfigStore.forPath(
        path,
      ).load()).playbackRetentionDays,
      7,
    );
  });
}
