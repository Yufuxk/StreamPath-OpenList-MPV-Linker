import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/utils/app_paths.dart';

/// AppPaths 布局迁移测试（config/ 与 cache/ 子目录）。
void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('sp_paths_');
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 在根下创建旧版平铺布局文件。
  void createLegacy(String name, [String content = 'x']) {
    File(
      '${tempRoot.path}${Platform.pathSeparator}$name',
    ).writeAsStringSync(content);
  }

  bool exists(String rel) =>
      File('${tempRoot.path}${Platform.pathSeparator}$rel').existsSync();

  test('配置文件迁移到 config/，缓存文件迁移到 cache/', () async {
    createLegacy('stream_path_config.json', '{"serverUrl":"x"}');
    createLegacy('cache_policy.json', '{"enabled":true}');
    createLegacy('cache_intelligence.json', '{"enabled":true}');
    createLegacy('streampath.db');
    createLegacy('playback_history.json');
    createLegacy('media_metadata.json');
    createLegacy('cache_intelligence_learning.json');
    createLegacy('mpv-current-session_1.txt');
    createLegacy('mpv-progress-session_1.jsonl');

    await AppPaths.migrateLegacyLayout(dataDir: tempRoot);

    expect(exists('config/stream_path_config.json'), isTrue);
    expect(exists('config/cache_policy.json'), isTrue);
    expect(exists('config/cache_intelligence.json'), isTrue);
    expect(exists('cache/streampath.db'), isTrue);
    expect(exists('cache/playback_history.json'), isTrue);
    expect(exists('cache/media_metadata.json'), isTrue);
    expect(exists('cache/cache_intelligence_learning.json'), isTrue);
    expect(exists('cache/mpv-current-session_1.txt'), isTrue);
    expect(exists('cache/mpv-progress-session_1.jsonl'), isTrue);
    // 原位置已清空。
    expect(exists('stream_path_config.json'), isFalse);
    expect(exists('streampath.db'), isFalse);
  });

  test('目录（mpv-watch-later/mpv-scripts）整体迁移到 cache/', () async {
    final wl = Directory(
      '${tempRoot.path}${Platform.pathSeparator}mpv-watch-later',
    )..createSync(recursive: true);
    File('${wl.path}${Platform.pathSeparator}abc123').writeAsStringSync('p');
    Directory(
      '${tempRoot.path}${Platform.pathSeparator}mpv-scripts',
    ).createSync(recursive: true);

    await AppPaths.migrateLegacyLayout(dataDir: tempRoot);

    expect(
      Directory(
        '${tempRoot.path}${Platform.pathSeparator}cache/mpv-watch-later',
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        '${tempRoot.path}${Platform.pathSeparator}'
        'cache/mpv-watch-later${Platform.pathSeparator}abc123',
      ).existsSync(),
      isTrue,
    );
    expect(
      Directory(
        '${tempRoot.path}${Platform.pathSeparator}cache/mpv-scripts',
      ).existsSync(),
      isTrue,
    );
  });

  test('目标已存在时不覆盖（用户数据优先）', () async {
    createLegacy('stream_path_config.json', 'legacy');
    // 新位置已有更新版本。
    final configDir = Directory(
      '${tempRoot.path}${Platform.pathSeparator}config',
    )..createSync(recursive: true);
    File(
      '${configDir.path}${Platform.pathSeparator}stream_path_config.json',
    ).writeAsStringSync('new');
    await AppPaths.migrateLegacyLayout(dataDir: tempRoot);
    final content = File(
      '${tempRoot.path}${Platform.pathSeparator}'
      'config${Platform.pathSeparator}stream_path_config.json',
    ).readAsStringSync();
    expect(content, 'new', reason: '已存在的目标不应被覆盖');
  });

  test('会话/播放列表/脚本产物（前缀通配）迁移到 cache/', () async {
    createLegacy('mpv-command-session_2.txt');
    createLegacy('streampath-playlist-play_1.m3u');
    createLegacy('subtitle-select.lua');
    // 无关文件留在原地。
    createLegacy('unrelated.txt');

    await AppPaths.migrateLegacyLayout(dataDir: tempRoot);

    expect(exists('cache/mpv-command-session_2.txt'), isTrue);
    expect(exists('cache/streampath-playlist-play_1.m3u'), isTrue);
    expect(exists('cache/subtitle-select.lua'), isTrue);
    expect(exists('unrelated.txt'), isTrue, reason: '无关文件不动');
  });

  test('重复调用幂等（第二次无副作用）', () async {
    createLegacy('streampath.db');
    await AppPaths.migrateLegacyLayout(dataDir: tempRoot);
    await AppPaths.migrateLegacyLayout(dataDir: tempRoot);
    expect(exists('cache/streampath.db'), isTrue);
    expect(exists('streampath.db'), isFalse);
  });
}
