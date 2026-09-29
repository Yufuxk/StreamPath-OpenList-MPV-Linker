import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/special_playlist_mode.dart';
import 'package:streampath/data/models/stream_path_config.dart';

void main() {
  test('旧配置默认仅 OVA、仅扫描子级，字体串用关闭', () {
    final config = StreamPathConfig.fromJson({'schemaVersion': 5});
    expect(config.specialPlaylistMode, SpecialPlaylistMode.ovaOnly);
    expect(config.scanSpecialChildFolders, isTrue);
    expect(config.scanSpecialSiblingFolders, isFalse);
    expect(config.sharePlaylistFonts, isFalse);
    expect(config.autoSeasonTransitionEnabled, isTrue);
    expect(config.allowSeasonGap, isFalse);
    final player = PlayerConfig.fromJson({});
    expect(player.specialPlaylistMode, SpecialPlaylistMode.ovaOnly);
    expect(player.scanSpecialChildFolders, isTrue);
    expect(player.scanSpecialSiblingFolders, isFalse);
    expect(player.autoSeasonTransitionEnabled, isTrue);
    expect(player.allowSeasonGap, isFalse);
  });

  test('全局播放器设置序列化后保持特典模式', () {
    final config = StreamPathConfig.defaults().copyWithGlobalSettings(
      player: const PlayerConfig(
        name: 'mpv',
        executable: 'mpv',
        specialPlaylistMode: SpecialPlaylistMode.all,
        scanSpecialChildFolders: false,
        scanSpecialSiblingFolders: true,
        sharePlaylistFonts: true,
        autoSeasonTransitionEnabled: false,
        allowSeasonGap: true,
      ),
      appearance: StreamPathConfig.defaults().appearance,
      mediaLibrary: StreamPathConfig.defaults().mediaLibrary,
    );
    final restored = StreamPathConfig.fromJson(config.toJson());
    expect(restored.specialPlaylistMode, SpecialPlaylistMode.all);
    expect(restored.scanSpecialChildFolders, isFalse);
    expect(restored.scanSpecialSiblingFolders, isTrue);
    expect(restored.sharePlaylistFonts, isTrue);
    expect(restored.autoSeasonTransitionEnabled, isFalse);
    expect(restored.allowSeasonGap, isTrue);
    expect(restored.toPlayerConfig().autoSeasonTransitionEnabled, isFalse);
    expect(
      restored.toPlayerConfig().specialPlaylistMode,
      SpecialPlaylistMode.all,
    );
    expect(restored.toPlayerConfig().scanSpecialChildFolders, isFalse);
    expect(restored.toPlayerConfig().scanSpecialSiblingFolders, isTrue);
  });

  test('历史路径与旧记录兼容', () {
    final history = PlaybackHistory(
      dirCrumbs: const ['Show'],
      fileName: 'OVA01.mkv',
      videoIndex: 1,
      updatedAt: DateTime(2026),
      playlistFileNames: const ['E01.mkv', 'OVA01.mkv'],
      playlistRelativePaths: const ['Show/E01.mkv', 'Show/Extras/OVA01.mkv'],
    );
    expect(
      PlaybackHistory.fromJson(history.toJson()).playlistRelativePaths,
      history.playlistRelativePaths,
    );
    final legacy = PlaybackHistory.fromJson({
      'dirCrumbs': ['Show'],
      'fileName': 'E01.mkv',
      'videoIndex': 0,
      'updatedAt': 0,
    });
    expect(legacy.playlistRelativePaths, isEmpty);
  });
}
