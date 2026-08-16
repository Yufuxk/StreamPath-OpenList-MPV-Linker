import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/audio_media_entry.dart';
import 'package:streampath/domain/services/audio_lyrics_localizer.dart';

void main() {
  test('远程 LRC 保留原始编码并转为会话文件', () async {
    final directory = Directory.systemTemp.createTempSync('audio_lrc_');
    addTearDown(() => directory.deleteSync(recursive: true));
    const sourceBytes = <int>[0xff, 0xfe, 0x5b, 0x00, 0x30, 0x00];
    int? requestedLimit;

    final result = await const AudioLyricsLocalizer().localize(
      entries: const [
        AudioMediaEntry(
          url: 'https://host/song.flac',
          title: '歌曲',
          lyrics: AudioCompanionFile(
            name: 'song.lrc',
            url: 'https://host/song.lrc',
          ),
        ),
      ],
      base: directory,
      sessionId: 'session/one',
      loader: (url, {required maxBytes, required timeout}) async {
        requestedLimit = maxBytes;
        return sourceBytes;
      },
    );

    expect(requestedLimit, AudioLyricsLocalizer.maxLyricsBytes);
    expect(result.sessionFiles, hasLength(1));
    expect(result.entries.single.lyrics?.url, result.sessionFiles.single.path);
    expect(await result.sessionFiles.single.readAsBytes(), sourceBytes);
  });

  test('远程 LRC 读取失败时只跳过歌词并保留封面', () async {
    final directory = Directory.systemTemp.createTempSync('audio_lrc_fail_');
    addTearDown(() => directory.deleteSync(recursive: true));

    final result = await const AudioLyricsLocalizer().localize(
      entries: const [
        AudioMediaEntry(
          url: 'https://host/song.flac',
          title: '歌曲',
          lyrics: AudioCompanionFile(
            name: 'song.lrc',
            url: 'https://host/song.lrc',
          ),
          coverArt: AudioCompanionFile(
            name: 'song.jpg',
            url: 'https://host/song.jpg',
          ),
        ),
      ],
      base: directory,
      sessionId: 'failure',
      loader: (url, {required maxBytes, required timeout}) =>
          throw StateError('读取失败'),
    );

    expect(result.entries.single.lyrics, isNull);
    expect(result.entries.single.coverArt?.url, 'https://host/song.jpg');
    expect(result.sessionFiles, isEmpty);
  });

  test('本地 LRC 不复制也不纳入会话清理', () async {
    final directory = Directory.systemTemp.createTempSync('audio_lrc_local_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final lyrics = File('${directory.path}${Platform.pathSeparator}song.lrc');
    await lyrics.writeAsString('[00:00.00]歌词');

    final result = await const AudioLyricsLocalizer().localize(
      entries: [
        AudioMediaEntry(
          url: 'C:/music/song.flac',
          title: '歌曲',
          lyrics: AudioCompanionFile(name: 'song.lrc', url: lyrics.path),
        ),
      ],
      base: directory,
      sessionId: 'local',
    );

    expect(result.entries.single.lyrics?.url, lyrics.path);
    expect(result.sessionFiles, isEmpty);
    expect(await lyrics.exists(), isTrue);
  });

  test('歌词准备超过总时限时移除未完成的远程引用', () async {
    final directory = Directory.systemTemp.createTempSync('audio_lrc_timeout_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final pending = Completer<List<int>>();
    final localizer = AudioLyricsLocalizer(
      preparationTimeout: const Duration(milliseconds: 30),
    );

    final result = await localizer.localize(
      entries: List.generate(
        8,
        (index) => AudioMediaEntry(
          url: 'https://host/$index.flac',
          title: '$index',
          lyrics: AudioCompanionFile(
            name: '$index.lrc',
            url: 'https://host/$index.lrc',
          ),
        ),
      ),
      base: directory,
      sessionId: 'timeout',
      loader: (url, {required maxBytes, required timeout}) => pending.future,
    );

    expect(result.entries.every((entry) => entry.lyrics == null), isTrue);
    expect(result.sessionFiles, isEmpty);
  });
}
