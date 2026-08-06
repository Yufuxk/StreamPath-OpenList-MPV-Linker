import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/domain/services/external_player_service.dart';

/// 播放列表（自动切集）参数组装。
///
/// 多集模式统一经 m3u 播放列表文件：每集标题（EXTINF）与窗口标题
/// （EXTVLCOPT force-media-title）由 mpv 原生绑定到对应条目，
/// 切集不错位；URL 直链在 m3u 中原样保留，字幕由 sub-add 脚本注入，
/// 续播由预写 watch_later 实现（见 launch 测试）。
void main() {
  final service = ExternalPlayerService(
    configStore: StreamPathConfigStore.forPath(
      '${Directory.systemTemp.path}${Platform.pathSeparator}none.json',
    ),
  );

  const config = PlayerConfig(
    name: 'mpv',
    executable: 'mpv',
    args: ['--sub-file={subfile}', '{url}', '--start={start}'],
  );

  const playlistPath =
      r'C:\tmp\sp-test\streampath-playlist.m3u';

  group('buildListArgs 播放列表参数', () {
    test('多集输出 --playlist 指向 m3u（无 --sub-file/--start/逐 URL）', () {
      final args = service.buildListArgs(
        config: config,
        authHeader: null,
        playlistPath: playlistPath,
      );
      expect(args, ['--playlist=$playlistPath']);
      expect(args.any((a) => a.contains('http://h/')), isFalse,
          reason: 'URL 在 m3u 文件中，不进参数');
      expect(args.any((a) => a.contains('--sub-file')), isFalse);
      expect(args.any((a) => a.contains('--start')), isFalse);
    });

    test('有字幕时列表参数仍不含 --sub-file（由脚本注入）', () {
      final args = service.buildListArgs(
        config: config,
        authHeader: null,
        playlistPath: playlistPath,
      );
      expect(args, ['--playlist=$playlistPath']);
    });

    test('playlistStart>0 时输出 --playlist-start（播放起点）', () {
      final args = service.buildListArgs(
        config: config,
        authHeader: null,
        playlistPath: playlistPath,
        playlistStart: 1,
      );
      expect(args, [
        '--playlist=$playlistPath',
        '--playlist-start=1',
      ]);
    });

    test('playlistStart=0 时不输出 --playlist-start', () {
      final args = service.buildListArgs(
        config: config,
        authHeader: null,
        playlistPath: playlistPath,
      );
      expect(args, ['--playlist=$playlistPath']);
    });

    test('认证 header 全局注入一次', () {
      final args = service.buildListArgs(
        config: config,
        authHeader: 'Basic eHl6',
        playlistPath: playlistPath,
      );
      expect(args.first, '--http-header-fields=Authorization: Basic eHl6');
      expect(args, [
        '--http-header-fields=Authorization: Basic eHl6',
        '--playlist=$playlistPath',
      ]);
    });

    test('静态模板项全局注入；{url} 项不再逐集展开', () {
      const staticConfig = PlayerConfig(
        name: 'mpv',
        executable: 'mpv',
        args: ['--no-config-file', '--sub-file={subfile}', '{url}'],
      );
      final args = service.buildListArgs(
        config: staticConfig,
        authHeader: null,
        playlistPath: playlistPath,
      );
      expect(args, [
        '--no-config-file', // 静态项 → 全局
        '--playlist=$playlistPath',
      ]);
    });
  });
}
