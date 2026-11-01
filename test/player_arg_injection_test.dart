import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/playback_media_info.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/iso_playback_service.dart';
import 'package:streampath/domain/services/local_disc_playback_service.dart';
import 'package:streampath/domain/services/remote_menu_playback_service.dart';

/// 启动参数分类注入：开关语义、元数据判定与各播放链路的参数过滤。
void main() {
  const animeArgs = [
    '--glsl-shaders=~~/shaders/Anime4K/Anime4K_Clamp_Highlights.glsl;'
        '~~/shaders/Anime4K/Anime4K_Restore_CNN_Soft_M.glsl',
    '--sub-file={subfile}',
    '{url}',
    '--start={start}',
  ];

  const placeholderArgs = ['--sub-file={subfile}', '{url}', '--start={start}'];

  const animeSeries = PlaybackMediaInfo(isSeries: true, isAnime: true);
  const animeMovie = PlaybackMediaInfo(isSeries: false, isAnime: true);
  const liveActionMovie = PlaybackMediaInfo(isSeries: false, isAnime: false);
  const liveActionSeries = PlaybackMediaInfo(isSeries: true, isAnime: false);

  group('PlayerConfig.argsFor 分类过滤', () {
    test('全部注入开启时不判断元数据', () {
      const config = PlayerConfig(
        name: 'mpv',
        executable: 'mpv',
        args: animeArgs,
      );
      expect(config.argsFor(null), animeArgs);
      expect(config.argsFor(liveActionMovie), animeArgs);
    });

    test('分类开关全部关闭时只保留占位符行', () {
      const config = PlayerConfig(
        name: 'mpv',
        executable: 'mpv',
        args: animeArgs,
        argInjectionAllEnabled: false,
      );
      expect(config.argsFor(animeSeries), placeholderArgs);
    });

    test('动漫注入只命中动画类型', () {
      const config = PlayerConfig(
        name: 'mpv',
        executable: 'mpv',
        args: animeArgs,
        argInjectionAllEnabled: false,
        argInjectionAnimeEnabled: true,
      );
      expect(config.argsFor(animeSeries), animeArgs);
      expect(config.argsFor(animeMovie), animeArgs);
      expect(config.argsFor(liveActionSeries), placeholderArgs);
      expect(config.argsFor(liveActionMovie), placeholderArgs);
      expect(config.argsFor(null), placeholderArgs, reason: '无元数据不注入');
    });

    test('电影注入与剧集注入按作品类型命中', () {
      const movie = PlayerConfig(
        name: 'mpv',
        executable: 'mpv',
        args: animeArgs,
        argInjectionAllEnabled: false,
        argInjectionMovieEnabled: true,
      );
      expect(movie.argsFor(liveActionMovie), animeArgs);
      expect(movie.argsFor(liveActionSeries), placeholderArgs);

      const series = PlayerConfig(
        name: 'mpv',
        executable: 'mpv',
        args: animeArgs,
        argInjectionAllEnabled: false,
        argInjectionSeriesEnabled: true,
      );
      expect(series.argsFor(liveActionSeries), animeArgs);
      expect(series.argsFor(liveActionMovie), placeholderArgs);
    });

    test('多个分类开关按或关系命中', () {
      const config = PlayerConfig(
        name: 'mpv',
        executable: 'mpv',
        args: animeArgs,
        argInjectionAllEnabled: false,
        argInjectionMovieEnabled: true,
        argInjectionAnimeEnabled: true,
      );
      expect(config.argsFor(liveActionMovie), animeArgs);
      expect(config.argsFor(animeSeries), animeArgs);
      expect(config.argsFor(liveActionSeries), placeholderArgs);
    });
  });

  group('playbackMediaInfoOf 元数据判定', () {
    test('类型缺失时返回 null', () {
      expect(playbackMediaInfoOf(null, const ['动画']), isNull);
      expect(playbackMediaInfoOf('person', const ['动画']), isNull);
    });

    test('动画类型名称兼容四种语言与大小写', () {
      for (final name in [
        'Animation',
        'animation',
        'Anime',
        '动画',
        '動畫',
        'アニメーション',
        'アニメ',
        '애니메이션',
      ]) {
        final info = playbackMediaInfoOf('tv', [name]);
        expect(info?.isAnime, isTrue, reason: name);
        expect(info?.isSeries, isTrue);
      }
      expect(playbackMediaInfoOf('movie', const ['动画'])?.isAnime, isTrue);
      expect(playbackMediaInfoOf('movie', const ['喜剧'])?.isAnime, isFalse);
    });

    test('兼容 {name} 对象形态的类型条目', () {
      final info = playbackMediaInfoOf('movie', const [
        {'name': '动画'},
        {'name': 'Action'},
      ]);
      expect(info?.isAnime, isTrue);
      expect(info?.isSeries, isFalse);
    });
  });

  test('分类开关随统一配置持久化，旧配置默认全部注入', () {
    final base = StreamPathConfig.defaults();
    const player = PlayerConfig(
      name: 'mpv',
      executable: 'mpv',
      args: animeArgs,
      argInjectionAllEnabled: false,
      argInjectionAnimeEnabled: true,
    );
    final config = base.copyWithGlobalSettings(
      player: player,
      appearance: base.appearance,
      mediaLibrary: base.mediaLibrary,
    );
    expect(config.argInjectionAllEnabled, isFalse);
    expect(config.argInjectionAnimeEnabled, isTrue);
    expect(config.toPlayerConfig().argInjectionAnimeEnabled, isTrue);

    final roundTrip = StreamPathConfig.fromJson(config.toJson());
    expect(roundTrip.argInjectionAllEnabled, isFalse);
    expect(roundTrip.argInjectionAnimeEnabled, isTrue);
    expect(roundTrip.argInjectionMovieEnabled, isFalse);
    expect(roundTrip.argInjectionSeriesEnabled, isFalse);

    final legacy = StreamPathConfig.fromJson(const {});
    expect(legacy.argInjectionAllEnabled, isTrue);
    expect(legacy.argInjectionAnimeEnabled, isFalse);
    expect(legacy.argInjectionMovieEnabled, isFalse);
    expect(legacy.argInjectionSeriesEnabled, isFalse);

    final playerRoundTrip = PlayerConfig.fromJson(player.toJson());
    expect(playerRoundTrip.argInjectionAllEnabled, isFalse);
    expect(playerRoundTrip.argInjectionAnimeEnabled, isTrue);
    expect(PlayerConfig.fromJson(const {}).argInjectionAllEnabled, isTrue);
  });

  group('光盘链路参数过滤', () {
    const gated = PlayerConfig(
      name: 'mpv',
      executable: 'mpv',
      args: animeArgs,
      argInjectionAllEnabled: false,
      argInjectionAnimeEnabled: true,
    );

    test('ISO 标题模式命中动漫时保留附加参数', () {
      final args = IsoPlaybackService.buildMpvArgs(
        config: gated,
        title: 'disc',
        playlistPath: r'C:\tmp\x.m3u',
        playlistStart: 0,
        progressScriptPath: r'C:\tmp\iso-current.txt',
        mediaInfo: animeSeries,
      );
      expect(args.any((a) => a.startsWith('--glsl-shaders=')), isTrue);
    });

    test('ISO 标题模式无元数据时不注入附加参数', () {
      final args = IsoPlaybackService.buildMpvArgs(
        config: gated,
        title: 'disc',
        playlistPath: r'C:\tmp\x.m3u',
        playlistStart: 0,
        progressScriptPath: r'C:\tmp\iso-current.txt',
      );
      expect(args.any((a) => a.startsWith('--glsl-shaders=')), isFalse);
      expect(args.any((a) => a.startsWith('--playlist=')), isTrue);
    });

    test('本地光盘链路同样按分类过滤', () {
      final hit = LocalDiscPlaybackService.buildMpvArgs(
        gated,
        devicePath: r'D:\movie.iso',
        mode: LocalDiscLaunchMode.longestTitle,
        ipcPipeName: r'\\.\pipe\test',
        mediaInfo: animeSeries,
      );
      expect(hit.any((a) => a.startsWith('--glsl-shaders=')), isTrue);

      final miss = LocalDiscPlaybackService.buildMpvArgs(
        gated,
        devicePath: r'D:\movie.iso',
        mode: LocalDiscLaunchMode.longestTitle,
        ipcPipeName: r'\\.\pipe\test',
        mediaInfo: liveActionMovie,
      );
      expect(miss.any((a) => a.startsWith('--glsl-shaders=')), isFalse);
      expect(miss.contains('bd://longest'), isTrue);
    });

    test('远程菜单链路同样按分类过滤', () {
      final scriptPath = r'C:\tmp\session\iso-current.txt';
      final endpoint = Uri.file(r'C:\tmp\session\disc\disc.iso');
      final hit = RemoteMenuPlaybackService.buildArgs(
        gated,
        endpoint: endpoint,
        ipcPipeName: r'\\.\pipe\menu',
        scriptPath: scriptPath,
        mediaInfo: animeSeries,
      );
      expect(hit.any((a) => a.startsWith('--glsl-shaders=')), isTrue);

      final miss = RemoteMenuPlaybackService.buildArgs(
        gated,
        endpoint: endpoint,
        ipcPipeName: r'\\.\pipe\menu',
        scriptPath: scriptPath,
        mediaInfo: liveActionMovie,
      );
      expect(miss.any((a) => a.startsWith('--glsl-shaders=')), isFalse);
      expect(miss.contains('bd://menu'), isTrue);
    });
  });
}
