/// 分类注入所需的影片元数据。
///
/// 由影视库作品的 `media_type` 与 `metadata_json.genres` 推导；null 表示
/// 本次播放没有可用元数据（资源未收录、未刮削或查询失败）。
library;

class PlaybackMediaInfo {
  const PlaybackMediaInfo({required this.isSeries, required this.isAnime});

  /// 作品类型为剧集（`media_type = tv`）。
  final bool isSeries;

  /// 类型名称包含动画类条目。
  final bool isAnime;
}

/// 动画类型名集合。
///
/// TMDB 按元数据语言返回本地化名称，Jellyfin／Emby 与本地 NFO 使用用户
/// 自带标签，因此按名称判定而不依赖 TMDB 类型 ID。
const Set<String> animationGenreNames = {
  'animation',
  'anime',
  '动画',
  '动画片',
  '動畫',
  '動畫片',
  'アニメ',
  'アニメーション',
  '애니메이션',
};

/// 由作品类型与类型条目推导分类注入信息；类型无法识别时返回 null。
///
/// [genres] 兼容 TMDB 的字符串数组与服务器／NFO 的 `{name: ...}` 对象数组。
PlaybackMediaInfo? playbackMediaInfoOf(
  String? mediaType,
  Iterable<Object?> genres,
) {
  if (mediaType != 'movie' && mediaType != 'tv') return null;
  var anime = false;
  for (final genre in genres) {
    final name = switch (genre) {
      final String value => value,
      final Map value => value['name'],
      _ => null,
    };
    if (name is String && animationGenreNames.contains(name.trim().toLowerCase())) {
      anime = true;
      break;
    }
  }
  return PlaybackMediaInfo(isSeries: mediaType == 'tv', isAnime: anime);
}
