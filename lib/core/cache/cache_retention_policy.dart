import '../constants.dart';

/// 各类可重建缓存的保留策略。
abstract interface class CacheRetentionPolicy {
  Duration get directoryFreshness;
  Duration get directoryRetention;
  Duration get directoryScrollRetention;
  Duration get playbackRetention;
  Duration get mediaMetadataRetention;
}

typedef CacheRetentionPolicyProvider = CacheRetentionPolicy Function();

/// 配置缺失或损坏时使用的安全默认策略。
class DefaultCacheRetentionPolicy implements CacheRetentionPolicy {
  const DefaultCacheRetentionPolicy();

  @override
  Duration get directoryFreshness => AppConstants.directoryCacheTtl;

  @override
  Duration get directoryRetention => AppConstants.directoryCacheRetention;

  @override
  Duration get directoryScrollRetention =>
      AppConstants.directoryScrollRetention;

  @override
  Duration get playbackRetention => AppConstants.playbackCacheRetention;

  @override
  Duration get mediaMetadataRetention =>
      AppConstants.mediaMetadataCacheRetention;
}
