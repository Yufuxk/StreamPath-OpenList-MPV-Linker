/// StreamPath 全局常量。
abstract final class AppConstants {
  /// 目录元数据缓存有效期（TTL）。10 分钟内视为新鲜，直接命中缓存实现"秒开"。
  static const Duration directoryCacheTtl = Duration(minutes: 10);

  /// 目录快照最长空闲时间；超过后不再展示旧快照并自动移除。
  static const Duration directoryCacheRetention = Duration(days: 30);

  /// 目录缓存最大条目数，避免 Hive 常驻内存随访问目录无限增长。
  static const int maxDirectoryCacheEntries = 512;

  /// 目录访问时间最小落盘间隔，避免连续读取造成无意义写放大。
  static const Duration directoryCacheTouchInterval = Duration(hours: 1);

  /// 浏览页滚动位置最长空闲时间与条目上限。
  static const Duration directoryScrollRetention = Duration(minutes: 30);
  static const int maxDirectoryScrollEntries = 128;

  /// 视频、音频续播进度及继续播放记录的最长保留时间。
  static const Duration playbackCacheRetention = Duration(days: 365);

  /// 媒体探测元数据的默认保留时间。
  static const Duration mediaMetadataCacheRetention = Duration(days: 180);

  /// 学习数据没有自动过期时间，只允许用户通过独立入口主动清理。
  static const Duration? cacheLearningRetention = null;

  /// 同时保留的播放会话/下边栏上限。
  ///
  /// 播放会话、持久化和界面均按集合实现；后续如需扩容只需调整此值，
  /// 无需修改下边栏或播放器服务的核心结构。
  static const int maxPlaybackSessions = 2;

  /// 新启动的 MPV 等待首个有效播放状态的默认时间（秒）。
  static const int defaultPlayerStartupTimeoutSeconds = 60;

  /// 配置文件允许的播放器启动等待范围。
  static const int minPlayerStartupTimeoutSeconds = 5;
  static const int maxPlayerStartupTimeoutSeconds = 3600;

  /// 播放器配置文件名（旧版，已并入 [AppConstants.configFileName]）。
  @Deprecated('已合并到 stream_path_config.json')
  static const String playerConfigFileName = 'player_config.json';

  /// WebDAV 连接配置文件名（旧版，已并入 [AppConstants.configFileName]）。
  @Deprecated('已合并到 stream_path_config.json')
  static const String connectionConfigFileName = 'connection_config.json';

  /// 统一配置文件（数据目录下，集中存放所有用户可配置信息）。
  static const String configFileName = 'stream_path_config.json';

  /// 上次播放记录文件名（数据目录下，动态更新）。
  static const String playbackHistoryFileName = 'playback_history.json';

  /// 音频播放记录文件名。与视频历史分开保存，单侧损坏不影响另一侧。
  static const String audioPlaybackHistoryFileName =
      'audio_playback_history.json';

  /// MPV 当前播放状态上报文件（数据目录下，由注入的 lua 脚本写入）。
  static const String mpvCurrentFileName = 'mpv-current.txt';

  /// MPV 命令文件（数据目录下，软件写入 pause/resume，由 lua 脚本轮询执行）。
  static const String mpvCommandFileName = 'mpv-command.txt';

  /// 可自动匹配的字幕扩展名（小写）。
  ///
  /// 覆盖常见文本字幕（srt/ass/vtt/ssa/smi）与二进制字幕
  /// （sub=MicroDVD/VobSub、sup=PGS、idx=VobSub 索引），
  /// mpv 均支持通过 `--sub-file` 加载。
  static const List<String> subtitleExtensions = [
    '.srt',
    '.ass',
    '.vtt',
    '.ssa',
    '.sub',
    '.sup',
    '.idx',
    '.smi',
  ];

  /// 可注入 MPV/libass 的字体文件扩展名（小写）。
  static const List<String> fontExtensions = ['.ttf', '.otf', '.ttc', '.otc'];

  /// 常见视频扩展名（小写）——用于识别"可播放"文件。
  static const List<String> videoExtensions = [
    '.mp4',
    '.mkv',
    '.avi',
    '.mov',
    '.wmv',
    '.flv',
    '.webm',
    '.ts',
    '.m2ts',
    '.rmvb',
    '.mpg',
    '.mpeg',
    '.3gp',
  ];

  /// 常见音频扩展名（小写）——用于识别音频播放项。
  static const List<String> audioExtensions = [
    '.mp3',
    '.flac',
    '.wav',
    '.m4a',
    '.m4b',
    '.m4p',
    '.aac',
    '.ogg',
    '.oga',
    '.opus',
    '.spx',
    '.wma',
    '.ape',
    '.alac',
    '.aiff',
    '.aif',
    '.aifc',
    '.mka',
    '.ac3',
    '.eac3',
    '.dts',
    '.amr',
    '.3ga',
    '.au',
    '.caf',
    '.mp2',
    '.mpc',
    '.tta',
    '.tak',
    '.dsf',
    '.dff',
    '.wv',
    '.ra',
    '.aa',
    '.aax',
    '.mlp',
    '.thd',
    '.mid',
    '.midi',
  ];

  /// LRC 歌词扩展名。
  static const List<String> lyricsExtensions = ['.lrc'];

  /// 可作为外挂封面的常见图片扩展名。
  static const List<String> coverArtExtensions = [
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.bmp',
    '.gif',
    '.avif',
    '.jxl',
    '.tif',
    '.tiff',
  ];

  /// strm 流指针文件扩展名（小写）——内容为一行媒体 URL，
  /// 播放时解析出真实地址交给播放器。
  static const List<String> strmExtensions = ['.strm'];

  /// Blu-ray ISO 光盘镜像扩展名。
  ///
  /// ISO 使用独立的远程 Bridge 播放链路，不属于普通视频或 STRM。
  static const List<String> isoExtensions = ['.iso'];

  /// 中文字幕语言标签（小写，`movie.zh.srt` / `movie.chs.ass` 等）。
  static const Set<String> chineseLangTags = {
    'zh',
    'zho',
    'chs',
    'cht',
    'sc',
    'tc',
    'gb',
    'gbk',
    'big5',
    'hans',
    'hant',
    '简',
    '繁',
    '简体',
    '繁体',
    '简中',
    '繁中',
    '中英',
    '双语',
    'bilingual',
    'zh-hans',
    'zh-hant',
    'zh-cn',
    'zh-tw',
    'zh-hk',
    'zh-sg',
  };

  /// 其他常见字幕语言标签（小写）——用于从文件名中剥离语言后缀，
  /// 避免把 `movie.en.srt` 之类的语言段误当作片名的一部分。
  static const Set<String> otherLangTags = {
    'en',
    'eng',
    'ja',
    'jpn',
    'ko',
    'kor',
    'fr',
    'fra',
    'de',
    'ger',
    'es',
    'spa',
    'ru',
    'rus',
    'it',
    'ita',
    'pt',
    'por',
    'ar',
    'ara',
    'th',
    'tha',
    'vi',
    'vie',
    'id',
    'ind',
    'tr',
    'tur',
    'nl',
    'dut',
    'pl',
    'pol',
    'sv',
    'swe',
    'no',
    'nor',
    'da',
    'dan',
    'fi',
    'fin',
    'cs',
    'ces',
    'hu',
    'hun',
    'ro',
    'ron',
    'el',
    'ell',
    'he',
    'heb',
    'hi',
    'hin',
    'uk',
    'ukr',
    'ms',
    'may',
    'fil',
    'fa',
    'fas',
    'bn',
    'ta',
    'te',
    'sr',
    'hr',
    'sk',
    'sl',
    'bg',
    'is',
    'lt',
    'lv',
    'et',
    'ka',
    'hy',
    'az',
    'uz',
    'kk',
    'mn',
    'ne',
    'si',
    'km',
    'lo',
    'my',
    'sw',
    'af',
    'cy',
    'ga',
    'eu',
    'ca',
    'gl',
    'sq',
    'mk',
    'be',
    'bs',
  };
}
