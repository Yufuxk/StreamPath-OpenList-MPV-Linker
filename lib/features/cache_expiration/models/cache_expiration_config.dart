import '../../../core/cache/cache_retention_policy.dart';
import '../../../core/constants.dart';

/// 可由用户修改的缓存过期配置。
class CacheExpirationConfig implements CacheRetentionPolicy {
  const CacheExpirationConfig({
    this.directoryFreshnessMinutes = defaultDirectoryFreshnessMinutes,
    this.directoryRetentionDays = defaultDirectoryRetentionDays,
    this.directoryScrollRetentionMinutes =
        defaultDirectoryScrollRetentionMinutes,
    this.playbackRetentionDays = defaultPlaybackRetentionDays,
    this.mediaMetadataRetentionDays = defaultMediaMetadataRetentionDays,
  });

  static const int defaultDirectoryFreshnessMinutes = 10;
  static const int defaultDirectoryRetentionDays = 30;
  static const int defaultDirectoryScrollRetentionMinutes = 30;
  static const int defaultPlaybackRetentionDays = 365;
  static const int defaultMediaMetadataRetentionDays = 180;

  static const int minMinutes = 1;
  static const int maxMinutes = 1440;
  static const int minDays = 1;
  static const int maxDays = 3650;

  final int directoryFreshnessMinutes;
  final int directoryRetentionDays;
  final int directoryScrollRetentionMinutes;
  final int playbackRetentionDays;
  final int mediaMetadataRetentionDays;

  @override
  Duration get directoryFreshness =>
      Duration(minutes: directoryFreshnessMinutes);

  @override
  Duration get directoryRetention => Duration(days: directoryRetentionDays);

  @override
  Duration get directoryScrollRetention =>
      Duration(minutes: directoryScrollRetentionMinutes);

  @override
  Duration get playbackRetention => Duration(days: playbackRetentionDays);

  @override
  Duration get mediaMetadataRetention =>
      Duration(days: mediaMetadataRetentionDays);

  static CacheExpirationConfig defaults() => const CacheExpirationConfig();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': 1,
    'directoryFreshnessMinutes': directoryFreshnessMinutes,
    'directoryRetentionDays': directoryRetentionDays,
    'directoryScrollRetentionMinutes': directoryScrollRetentionMinutes,
    'playbackRetentionDays': playbackRetentionDays,
    'mediaMetadataRetentionDays': mediaMetadataRetentionDays,
    'learningRetention': null,
  };

  factory CacheExpirationConfig.fromJson(Map<String, dynamic> json) =>
      CacheExpirationConfig(
        directoryFreshnessMinutes: _bounded(
          json['directoryFreshnessMinutes'],
          defaultDirectoryFreshnessMinutes,
          minMinutes,
          maxMinutes,
        ),
        directoryRetentionDays: _bounded(
          json['directoryRetentionDays'],
          defaultDirectoryRetentionDays,
          minDays,
          maxDays,
        ),
        directoryScrollRetentionMinutes: _bounded(
          json['directoryScrollRetentionMinutes'],
          defaultDirectoryScrollRetentionMinutes,
          minMinutes,
          maxMinutes,
        ),
        playbackRetentionDays: _bounded(
          json['playbackRetentionDays'],
          defaultPlaybackRetentionDays,
          minDays,
          maxDays,
        ),
        mediaMetadataRetentionDays: _bounded(
          json['mediaMetadataRetentionDays'],
          defaultMediaMetadataRetentionDays,
          minDays,
          maxDays,
        ),
      );

  static int _bounded(Object? value, int fallback, int min, int max) =>
      value is num ? value.toInt().clamp(min, max) : fallback;

  static bool get learningAutomaticallyExpires =>
      AppConstants.cacheLearningRetention != null;
}
