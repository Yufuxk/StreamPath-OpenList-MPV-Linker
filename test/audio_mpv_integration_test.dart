@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/models/audio_media_entry.dart';
import 'package:streampath/domain/services/audio_mpv_scripts.dart';

void main() {
  const mpvExecutable = r'D:\MPV_Player\mpv_config-2026.04.14\mpv.exe';

  test(
    '真实 MPV 可加载 M3U8、自定义曲名、LRC 与外挂封面',
    () async {
      if (!File(mpvExecutable).existsSync()) {
        markTestSkipped('未检测到项目实测 MPV');
        return;
      }
      final directory = Directory.systemTemp.createTempSync('audio_mpv_real_');
      final audio = File(p.join(directory.path, 'song.wav'));
      final lyrics = File(p.join(directory.path, 'song.lrc'));
      final cover = File(p.join(directory.path, 'song.png'));
      final status = p.join(directory.path, 'status.txt');
      final command = p.join(directory.path, 'command.txt');
      final progress = p.join(directory.path, 'progress.jsonl');
      await audio.writeAsBytes(_silentWave(seconds: 2), flush: true);
      await lyrics.writeAsString('[00:00.00]StreamPath 音频歌词\n', flush: true);
      await cover.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
        flush: true,
      );
      final entries = [
        AudioMediaEntry(
          url: audio.path,
          title: '自定义曲名',
          lyrics: AudioCompanionFile(
            name: lyrics.uri.pathSegments.last,
            url: lyrics.path,
          ),
          coverArt: AudioCompanionFile(
            name: cover.uri.pathSegments.last,
            url: cover.path,
          ),
        ),
      ];
      final playlist = await AudioMpvScripts.ensurePlaylistM3u8(
        entries,
        (value) => value,
        directory,
        sessionId: 'real',
      );
      final companions = await AudioMpvScripts.ensureCompanions(
        entries,
        (value) => value,
        directory,
        sessionId: 'real',
        lyricsInjectionEnabled: true,
        lyricsAutoSelectEnabled: true,
      );
      final current = await AudioMpvScripts.ensureCurrent(
        status,
        command,
        progress,
        directory,
        sessionId: 'real',
      );

      final process = await Process.start(mpvExecutable, [
        '--no-config',
        '--terminal=yes',
        '--msg-level=all=v',
        '--vo=null',
        '--ao=null',
        '--idle=no',
        '--keep-open=no',
        '--audio-display=embedded-first',
        '--cover-art-auto=no',
        '--sub-auto=no',
        '--script=$companions',
        '--script=$current',
        '--playlist=$playlist',
      ]);
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      final stdout = await stdoutFuture;
      final stderr = await stderrFuture;
      final output = '$stdout\n$stderr';
      try {
        expect(exitCode, 0, reason: output);
        expect(output, contains('自定义曲名'));
        expect(output, contains('song.lrc'));
        expect(output, contains('song.png'));
        expect(output, contains('● Image  --vid=1'));
        expect(output, isNot(contains('Invalid parameter for video-add')));
        final records = await File(progress).readAsLines();
        expect(records, isNotEmpty);
        expect(jsonDecode(records.last)['outcome'], 'completed');
      } finally {
        try {
          directory.deleteSync(recursive: true);
        } on FileSystemException {
          // MPV 退出后文件被安全软件短暂占用时交由临时目录回收。
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Uint8List _silentWave({required int seconds}) {
  const sampleRate = 8000;
  const channels = 1;
  const bitsPerSample = 16;
  final dataLength = sampleRate * seconds * channels * (bitsPerSample ~/ 8);
  final bytes = ByteData(44 + dataLength);

  void ascii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * channels * 2, Endian.little);
  bytes.setUint16(32, channels * 2, Endian.little);
  bytes.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, dataLength, Endian.little);
  return bytes.buffer.asUint8List();
}
