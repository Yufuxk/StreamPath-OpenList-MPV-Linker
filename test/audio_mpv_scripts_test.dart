import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/audio_media_entry.dart';
import 'package:streampath/domain/services/audio_mpv_scripts.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('audio_mpv_scripts_');
  });

  tearDown(() {
    directory.deleteSync(recursive: true);
  });

  test('M3U8 保存自定义曲名、认证后的 URL 且隔离会话文件名', () async {
    const entries = [
      AudioMediaEntry(url: 'http://h/01.flac', title: '第一首'),
      AudioMediaEntry(url: 'http://h/02.flac', title: '第二首'),
    ];

    final path = await AudioMpvScripts.ensurePlaylistM3u8(
      entries,
      (url) => url.replaceFirst('http://h', 'http://user:@h'),
      directory,
      sessionId: 'audio/session',
    );
    final content = await File(path).readAsString();

    expect(path, endsWith('streampath-audio-playlist-audio_session.m3u8'));
    expect(content, contains('#EXTINF:-1,第一首'));
    expect(content, contains('#EXTVLCOPT:force-media-title=第二首'));
    expect(content, contains('http://user:@h/01.flac'));
  });

  test('伴随脚本按 playlist-pos 注入 LRC 和外挂封面', () async {
    final path = await AudioMpvScripts.ensureCompanions(
      const [
        AudioMediaEntry(
          url: 'http://h/01.flac',
          title: '01',
          lyrics: AudioCompanionFile(name: '01.lrc', url: 'http://h/01.lrc'),
          coverArt: AudioCompanionFile(name: '01.jpg', url: 'http://h/01.jpg'),
        ),
      ],
      (url) => url,
      directory,
      sessionId: 'one',
      lyricsInjectionEnabled: true,
      lyricsAutoSelectEnabled: true,
    );
    final script = await File(path).readAsString();

    expect(script, contains('get_property_number("playlist-pos", -1)'));
    expect(script, contains('local LYRIC_MODE = "select"'));
    expect(script, contains('mp.commandv("sub-add", lyric, LYRIC_MODE'));
    expect(
      script,
      contains('mp.get_property("vid", "no") == "no" and "select" or "auto"'),
    );
    expect(script, contains('mp.commandv("video-add", cover, cover_mode'));
    expect(script, contains('"und", "yes")'));
  });

  test('关闭 LRC 自动选择时注入轨道并恢复原 sid', () async {
    final path = await AudioMpvScripts.ensureCompanions(
      const [
        AudioMediaEntry(
          url: 'http://h/01.flac',
          title: '01',
          lyrics: AudioCompanionFile(name: '01.lrc', url: 'http://h/01.lrc'),
        ),
      ],
      (url) => url,
      directory,
      sessionId: 'auto',
      lyricsInjectionEnabled: true,
      lyricsAutoSelectEnabled: false,
    );
    final script = await File(path).readAsString();

    expect(script, contains('local LYRIC_MODE = "auto"'));
    expect(
      script,
      contains('local previous_sid = mp.get_property("sid", "no")'),
    );
    expect(script, contains('mp.set_property("sid", previous_sid)'));
  });

  test('关闭 LRC 注入时脚本仍保留封面且不含歌词逻辑', () async {
    final path = await AudioMpvScripts.ensureCompanions(
      const [
        AudioMediaEntry(
          url: 'http://h/01.flac',
          title: '01',
          lyrics: AudioCompanionFile(name: '01.lrc', url: 'http://h/01.lrc'),
          coverArt: AudioCompanionFile(name: '01.jpg', url: 'http://h/01.jpg'),
        ),
      ],
      (url) => url,
      directory,
      sessionId: 'disabled',
      lyricsInjectionEnabled: false,
      lyricsAutoSelectEnabled: false,
    );
    final script = await File(path).readAsString();

    expect(script, isNot(contains('http://h/01.lrc')));
    expect(script, isNot(contains('sub-add')));
    expect(script, contains('http://h/01.jpg'));
    expect(script, contains('video-add'));
  });

  test('音频状态脚本不读取或修改缓存属性', () async {
    final path = await AudioMpvScripts.ensureCurrent(
      '${directory.path}/status.txt',
      '${directory.path}/command.txt',
      '${directory.path}/progress.jsonl',
      directory,
      sessionId: 'one',
      launchEpoch: 'audio-epoch-one',
    );
    final script = await File(path).readAsString();

    expect(script, contains('mp.register_event("end-file"'));
    expect(script, contains('append_progress("completed"'));
    expect(script, contains('mp.add_periodic_timer(0.25, poll_command)'));
    expect(
      script,
      contains(
        'file:write("-1\\n" .. tostring(last_playlist_pos) .. '
        '"\\n" .. EPOCH)',
      ),
    );
    expect(
      script,
      contains(
        'if has_loaded and not mp.get_property_bool("idle-active", false) then',
      ),
    );
    expect(script, isNot(contains('cache-')));
    expect(script, isNot(contains('demuxer-cache')));
  });
}
