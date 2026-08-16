import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/audio_media_entry.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/audio_player_service.dart';
import 'package:streampath/domain/services/mpv_watch_later_sync.dart';

void main() {
  test('缓存参数过滤覆盖应用缓存控制使用的 MPV 参数族', () {
    final filtered = AudioPlayerService.filterCacheArgs(const [
      '--profile=gpu --cache=yes --cache-secs=300',
      '--demuxer-max-bytes=1G',
      '--demuxer-max-back-bytes=100M',
      '--demuxer-seekable-cache=yes',
      '--cache-pause-wait=10',
      '--stream-buffer-size=4M',
      '--cache yes --cache-secs 90 --volume=60',
      '--demuxer-max-bytes 500M',
      '--volume=70',
    ]);

    expect(filtered, ['--profile=gpu', '--volume=60', '--volume=70']);
  });

  test('音频启动生成 M3U8、LRC/封面脚本且最终参数没有缓存覆盖', () async {
    sqfliteFfiInit();
    final directory = Directory.systemTemp.createTempSync('audio_launch_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final executable = File(
      '${directory.path}${Platform.pathSeparator}mpv-audio-test.exe',
    );
    await File(r'C:\Windows\System32\where.exe').copy(executable.path);
    final store = StreamPathConfigStore.forPath(
      '${directory.path}${Platform.pathSeparator}config.json',
    );
    await store.save(
      StreamPathConfig.fromParts(
        PlayerConfig(
          name: 'mpv',
          executable: executable.path,
          args: const [
            '--cache=yes',
            '--cache-secs=500',
            '--demuxer-max-bytes=2G',
            '{url}',
          ],
          subtitleAutoSelectEnabled: false,
        ),
        const ConnectionConfig(baseUrl: 'http://h/dav'),
      ),
    );
    final progress = await PlaybackProgressService.open(
      '${directory.path}${Platform.pathSeparator}audio.db',
      factory: databaseFactoryFfi,
    );
    addTearDown(progress.close);
    final service = AudioPlayerService(
      configStore: store,
      progressService: progress,
      watchLaterDirectory: Directory(
        '${directory.path}${Platform.pathSeparator}watch_later',
      ),
    );

    final result = await service.launch(
      sessionId: 'audio-one',
      playlistStart: 1,
      entries: const [
        AudioMediaEntry(url: 'http://h/dav/01.flac', title: '第一首'),
        AudioMediaEntry(
          url: 'http://h/dav/02.flac',
          title: '第二首',
          lyrics: AudioCompanionFile(
            name: '02.lrc',
            url: 'http://h/dav/02.lrc',
          ),
          coverArt: AudioCompanionFile(
            name: '02.jpg',
            url: 'http://h/dav/02.jpg',
          ),
        ),
      ],
      username: 'guest',
      password: '',
      lyricsLoader: (url, {required maxBytes, required timeout}) async =>
          '[00:00.00]第二首'.codeUnits,
    );

    expect(result.playlistFilePath, endsWith('.m3u8'));
    expect(result.args, contains('--playlist-start=1'));
    expect(result.args, contains('--audio-display=embedded-first'));
    expect(result.args, contains('--cover-art-auto=no'));
    expect(
      result.args.any(
        (argument) =>
            argument.toLowerCase().contains('--cache') ||
            argument.toLowerCase().contains('--demuxer-max') ||
            argument.toLowerCase().contains('--stream-buffer-size'),
      ),
      isFalse,
    );
    final m3u8 = await File(result.playlistFilePath).readAsString();
    expect(m3u8, contains('#EXTINF:-1,第二首'));
    expect(m3u8, contains('http://guest:@h/dav/02.flac'));
    final companionPath = result.args
        .where((arg) => arg.contains('audio-companions'))
        .single
        .substring('--script='.length);
    final companion = await File(companionPath).readAsString();
    expect(companion, isNot(contains('http://guest:@h/dav/02.lrc')));
    expect(companion, contains('streampath-audio-lyrics-audio-one-1.lrc'));
    expect(companion, contains('http://guest:@h/dav/02.jpg'));
    expect(companion, contains('local LYRIC_MODE = "auto"'));
    expect(companion, contains('mp.set_property("sid", previous_sid)'));
    await service.terminateSession('audio-one');
  });

  test('关闭字幕注入与续播时音频不加载 LRC 且封面仍然生效', () async {
    sqfliteFfiInit();
    final directory = Directory.systemTemp.createTempSync(
      'audio_settings_off_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final executable = File(
      '${directory.path}${Platform.pathSeparator}mpv-audio-test.exe',
    );
    await File(r'C:\Windows\System32\where.exe').copy(executable.path);
    final store = StreamPathConfigStore.forPath(
      '${directory.path}${Platform.pathSeparator}config.json',
    );
    await store.save(
      StreamPathConfig.fromParts(
        PlayerConfig(
          name: 'mpv',
          executable: executable.path,
          args: const ['{url}'],
          subtitleInjectionEnabled: false,
          subtitleAutoSelectEnabled: false,
          resumeEnabled: false,
        ),
        const ConnectionConfig(baseUrl: 'http://h/dav'),
      ),
    );
    final progress = await PlaybackProgressService.open(
      '${directory.path}${Platform.pathSeparator}audio.db',
      factory: databaseFactoryFfi,
    );
    addTearDown(progress.close);
    final service = AudioPlayerService(
      configStore: store,
      progressService: progress,
      watchLaterDirectory: Directory(
        '${directory.path}${Platform.pathSeparator}watch_later',
      ),
    );

    final result = await service.launch(
      sessionId: 'audio-off',
      playlistStart: 0,
      resumeSeconds: 88,
      entries: const [
        AudioMediaEntry(
          url: 'http://h/dav/song.flac',
          title: '歌曲',
          lyrics: AudioCompanionFile(
            name: 'song.lrc',
            url: 'http://h/dav/song.lrc',
          ),
          coverArt: AudioCompanionFile(
            name: 'song.jpg',
            url: 'http://h/dav/song.jpg',
          ),
        ),
      ],
    );

    expect(result.args, isNot(contains('--sub-auto=no')));
    expect(result.args, isNot(contains('--save-position-on-quit')));
    expect(
      result.args.any(
        (argument) => argument.startsWith('--watch-later-directory='),
      ),
      isFalse,
    );
    expect(result.args, isNot(contains('--start=88')));
    final companionPath = result.args
        .where((arg) => arg.contains('audio-companions'))
        .single
        .substring('--script='.length);
    final companion = await File(companionPath).readAsString();
    expect(companion, isNot(contains('song.lrc')));
    expect(companion, isNot(contains('sub-add')));
    expect(companion, contains('song.jpg'));
    expect(companion, contains('video-add'));
    await service.waitForExitSync('audio-off');
  });

  test('应用重启后可从遗留 JSONL 与 watch_later 恢复音频进度', () async {
    sqfliteFfiInit();
    final directory = Directory.systemTemp.createTempSync('audio_resume_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = StreamPathConfigStore.forPath(
      '${directory.path}${Platform.pathSeparator}config.json',
    );
    await store.save(
      StreamPathConfig.fromParts(
        PlayerConfig.defaultMpv(),
        const ConnectionConfig(baseUrl: 'http://h/dav'),
      ),
    );
    final progress = await PlaybackProgressService.open(
      '${directory.path}${Platform.pathSeparator}audio.db',
      factory: databaseFactoryFfi,
    );
    addTearDown(progress.close);
    final watchLater = Directory(
      '${directory.path}${Platform.pathSeparator}watch_later',
    )..createSync();
    final service = AudioPlayerService(
      configStore: store,
      progressService: progress,
      watchLaterDirectory: watchLater,
    );
    const url = 'http://h/dav/song.flac';
    await File(
      '${watchLater.path}${Platform.pathSeparator}'
      '${MpvWatchLaterSync.md5FileName(url)}',
    ).writeAsString('start=123.5\nduration=300\n');
    final journal = File(
      '${directory.path}${Platform.pathSeparator}progress.jsonl',
    );
    await journal.writeAsString(
      '{"outcome":"position","playlist_pos":0,'
      '"path":"$url","position":120,"duration":300}\n',
    );

    await service.syncPersistedProgress(
      sessionId: 'audio-resume',
      entries: const [AudioMediaEntry(url: url, title: 'Song')],
      journalFile: journal,
    );

    expect((await progress.getProgress(url))?.positionMs, 123500);
  });
}
