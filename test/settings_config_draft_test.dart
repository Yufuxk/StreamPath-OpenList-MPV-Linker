import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/media_library_config.dart';
import 'package:streampath/data/models/openlist_index_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/features/cache_control/models/cache_intelligence_config.dart';
import 'package:streampath/features/cache_control/models/cache_policy_config.dart';
import 'package:streampath/features/cache_expiration/models/cache_expiration_config.dart';
import 'package:streampath/presentation/models/settings_config_draft.dart';

void main() {
  test('WebDAV 字体缓存默认开启，关闭值在配置与草稿中保留', () {
    expect(StreamPathConfig.fromJson({}).webDavFontCacheEnabled, isTrue);
    const disabled = StreamPathConfig(webDavFontCacheEnabled: false);
    final restored = StreamPathConfig.fromJson(disabled.toJson());
    expect(restored.toPlayerConfig().webDavFontCacheEnabled, isFalse);
    final draft = SettingsConfigDraft();
    addTearDown(draft.dispose);
    draft.loadFrom(
      fullConfig: restored,
      appearance: restored.appearance,
      cacheConfig: const CachePolicyConfig(),
      intelligenceConfig: const CacheIntelligenceConfig(),
      expirationConfig: const CacheExpirationConfig(),
    );
    expect(draft.buildPlayerConfig().webDavFontCacheEnabled, isFalse);
  });
  test('菜单进度默认独立，共享设置在 JSON 与播放器配置间保留', () {
    final defaults = StreamPathConfig.fromJson({});
    expect(defaults.menuProgressSharingEnabled, isFalse);
    expect(defaults.toPlayerConfig().menuProgressSharingEnabled, isFalse);
    const shared = StreamPathConfig(menuProgressSharingEnabled: true);
    final restored = StreamPathConfig.fromJson(shared.toJson());
    expect(restored.toPlayerConfig().menuProgressSharingEnabled, isTrue);
    final copied = restored.copyWithGlobalSettings(
      player: restored.toPlayerConfig(),
      appearance: restored.appearance,
      mediaLibrary: restored.mediaLibrary,
    );
    expect(copied.menuProgressSharingEnabled, isTrue);
  });
  test('动态歌词默认开启，显式关闭与样式跨配置草稿保存', () {
    expect(StreamPathConfig.fromJson({}).audioDynamicLyricsEnabled, isTrue);
    const customized = StreamPathConfig(
      audioDynamicLyricsEnabled: false,
      audioLyricsFontFamily: 'Noto Sans CJK JP',
      audioLyricsOutlineWidth: 3.5,
      audioLyricsTransparency: 0.4,
    );
    final restored = StreamPathConfig.fromJson(customized.toJson());
    expect(restored.toPlayerConfig().audioDynamicLyricsEnabled, isFalse);
    expect(restored.toPlayerConfig().audioLyricsFontFamily, 'Noto Sans CJK JP');
    expect(restored.toPlayerConfig().audioLyricsOutlineWidth, 3.5);
    expect(restored.toPlayerConfig().audioLyricsTransparency, 0.4);
    final copied = restored.copyWithGlobalSettings(
      player: restored.toPlayerConfig(),
      appearance: restored.appearance,
      mediaLibrary: restored.mediaLibrary,
    );
    expect(copied.audioLyricsFontFamily, 'Noto Sans CJK JP');
    expect(copied.audioLyricsOutlineWidth, 3.5);
    expect(copied.audioLyricsTransparency, 0.4);
    final draft = SettingsConfigDraft();
    addTearDown(draft.dispose);
    draft.loadFrom(
      fullConfig: restored,
      appearance: restored.appearance,
      cacheConfig: const CachePolicyConfig(),
      intelligenceConfig: const CacheIntelligenceConfig(),
      expirationConfig: const CacheExpirationConfig(),
    );
    expect(draft.buildPlayerConfig().audioDynamicLyricsEnabled, isFalse);
    expect(draft.buildPlayerConfig().audioLyricsFontFamily, 'Noto Sans CJK JP');
    expect(draft.buildPlayerConfig().audioLyricsOutlineWidth, 3.5);
    expect(draft.buildPlayerConfig().audioLyricsTransparency, 0.4);
  });
  test('配置草稿加载后按原语义构建各配置模型', () {
    final draft = SettingsConfigDraft();
    addTearDown(draft.dispose);
    const fullConfig = StreamPathConfig(
      serverUrl: 'https://example.test/dav',
      username: 'user',
      password: 'secret',
      playerName: 'mpv-custom',
      playerExecutable: 'D:/mpv/mpv.exe',
      playerArgs: ['--pause', '{url}'],
      subtitleInjectionEnabled: true,
      subtitleAutoSelectEnabled: false,
      menuProgressSharingEnabled: true,
      hiddenExtensions: ['.ass'],
      mediaLibrary: MediaLibraryConfig(
        maxFavoritesPerSource: 123,
        sharingMode: MediaLibrarySharingMode.allShared,
      ),
    );
    const appearance = AppearanceConfig(
      style: InterfaceStyle.glass,
      material: WindowMaterialPreference.acrylic,
      glassOpacity: 0.76,
    );
    const cache = CachePolicyConfig(
      memoryBudgetRatio: 0.4,
      baseCacheSecs: 180,
      assumedBandwidthMbps: 80,
    );
    const intelligence = CacheIntelligenceConfig(
      minSamples: 9,
      maxAdjustmentRatio: 0.15,
    );
    const expiration = CacheExpirationConfig(
      directoryFreshnessMinutes: 20,
      playbackRetentionDays: 90,
    );

    draft.loadFrom(
      fullConfig: fullConfig,
      appearance: appearance,
      cacheConfig: cache,
      intelligenceConfig: intelligence,
      expirationConfig: expiration,
    );

    expect(
      draft.buildPlayerConfig().toJson(),
      fullConfig.toPlayerConfig().toJson(),
    );
    expect(draft.buildAppearanceConfig().toJson(), appearance.toJson());
    expect(draft.buildCachePolicyConfig().toJson(), cache.toJson());
    expect(draft.buildIntelligenceConfig().toJson(), intelligence.toJson());
    expect(draft.buildExpirationConfig().toJson(), expiration.toJson());
    expect(draft.buildMediaLibraryConfig().maxFavoritesPerSource, 123);
    expect(
      draft.buildMediaLibraryConfig().sharingMode,
      MediaLibrarySharingMode.allShared,
    );
    final profile = draft.buildProfile(profileId: 'profile-id');
    expect(profile.serverUrl, fullConfig.serverUrl);
    expect(profile.username, fullConfig.username);
    expect(profile.password, fullConfig.password);
    draft.openListIndexAutoUpdateEnabled = true;
    draft.openListIndexUserTokenController.text = 'user-token';
    draft.openListIndexIntervalController.text = '1';
    expect(
      draft.buildOpenListIndexConfig().updateIntervalMinutes,
      OpenListIndexConfig.minUpdateIntervalMinutes,
    );
    expect(draft.buildOpenListIndexConfig().userToken, 'user-token');
  });
}
