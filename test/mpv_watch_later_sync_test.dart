import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/mpv_watch_later_sync.dart';

void main() {
  group('MpvWatchLaterSync start= 解析', () {
    test('标准 mpv 输出', () {
      final content = '# http://host/dav/movie.mp4\nstart=123.456\naid=1\n';
      expect(MpvWatchLaterSync.parseStart(content), closeTo(123.456, 0.001));
    });

    test('容错格式（start 两侧空白）', () {
      final content = 'mute=no\n  start = 90.5  \nvolume=50\n';
      expect(MpvWatchLaterSync.parseStart(content), closeTo(90.5, 0.001));
    });

    test('0 是有效起点，无 start 或非法值返回 null', () {
      expect(MpvWatchLaterSync.parseStart('volume=50\n'), isNull);
      expect(MpvWatchLaterSync.parseStart('start=abc\n'), isNull);
      expect(MpvWatchLaterSync.parseStart('start=0\n'), 0);
      expect(MpvWatchLaterSync.parseStart(''), isNull);
    });
  });

  group('duration= 解析与读取（已看完判定用）', () {
    test('parseDuration 解析 mpv 0.36+ 的 duration 行', () {
      expect(
        MpvWatchLaterSync.parseDuration('start=300\nduration=1423.0\n'),
        closeTo(1423.0, 0.001),
      );
      expect(MpvWatchLaterSync.parseDuration('start=300\n'), isNull);
      expect(MpvWatchLaterSync.parseDuration('duration=abc\n'), isNull);
      expect(MpvWatchLaterSync.parseDuration('duration=0\n'), isNull);
    });

    test('readDurationSeconds 按 MD5 直查', () async {
      final dir = Directory.systemTemp.createTempSync('wl_dur_');
      addTearDown(() => dir.deleteSync(recursive: true));
      const url = 'http://host/dav/a.mp4';
      File(
        '${dir.path}${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(url)}',
      ).writeAsString('start=120\nduration=1423.0\n');

      const sync = MpvWatchLaterSync();
      expect(await sync.readDurationSeconds(dir, url), closeTo(1423.0, 0.001));
      expect(await sync.readStartSeconds(dir, url), closeTo(120, 0.001));
    });

    test('readDurationSeconds 无 duration 行返回 null', () async {
      final dir = Directory.systemTemp.createTempSync('wl_dur2_');
      addTearDown(() => dir.deleteSync(recursive: true));
      const url = 'http://host/dav/b.mp4';
      File(
        '${dir.path}${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(url)}',
      ).writeAsString('start=90\n');

      const sync = MpvWatchLaterSync();
      expect(await sync.readDurationSeconds(dir, url), isNull);
    });
  });

  group('md5FileName 命名（mpv 默认，已实测确认）', () {
    test('URL 的 MD5 大写 hex', () {
      // 实测值：mpv 播放 http://127.0.0.1:18080/dav/test.wav 生成
      // 3347FAA6E27536F7F05DD95A4E2B4668。
      expect(
        MpvWatchLaterSync.md5FileName('http://127.0.0.1:18080/dav/test.wav'),
        '3347FAA6E27536F7F05DD95A4E2B4668',
      );
      // 本地路径同样适用（与用户既有记录一致）。
      expect(
        MpvWatchLaterSync.md5FileName(r'C:\a\movie.mp4'),
        '03E57F0C70704CF7CAB1E481C6E0F3C8',
      );
    });
  });

  group('readStartSeconds 目录扫描匹配', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('wl_test_');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> writeRecord(String fileName, String content) => File(
      '${dir.path}${Platform.pathSeparator}$fileName',
    ).writeAsString(content);

    test('MD5 文件名直查（HTTP 流无注释行，mpv 实测格式）', () async {
      const url = 'http://127.0.0.1:18080/dav/test.wav';
      await writeRecord(MpvWatchLaterSync.md5FileName(url), 'start=0.465951\n');

      const sync = MpvWatchLaterSync();
      expect(
        await sync.readStartSeconds(dir, url),
        closeTo(0.465951, 0.000001),
      );
    });

    test('本地路径记录（带注释行）也可匹配', () async {
      await writeRecord(
        'FCD93DCF75B5974306E37F149FC858AF',
        '# C:\\Users\\YX\\Desktop\\movie.flac\nstart=3660.5\n',
      );

      const sync = MpvWatchLaterSync();
      expect(
        await sync.readStartSeconds(dir, r'C:\Users\YX\Desktop\movie.flac'),
        closeTo(3660.5, 0.001),
      );
    });

    test('sanitize 命名（write-filename-in-watch-later-config）也可匹配', () async {
      // 文件名与 URL 无关，匹配完全依赖首行注释。
      await writeRecord(
        'wl_sanitized_a.mp4',
        '# http://host/dav/a.mp4\nstart=90\n',
      );

      const sync = MpvWatchLaterSync();
      expect(
        await sync.readStartSeconds(dir, 'http://host/dav/a.mp4'),
        closeTo(90, 0.001),
      );
    });

    test('注释行带引号也可匹配', () async {
      await writeRecord('x1', '# "http://host/b.mp4"\nstart=12\n');

      const sync = MpvWatchLaterSync();
      expect(
        await sync.readStartSeconds(dir, 'http://host/b.mp4'),
        closeTo(12, 0.001),
      );
    });

    test('无关文件（其他 URL/无注释）不影响匹配', () async {
      await writeRecord('a1', '# http://host/other.mp4\nstart=10\n');
      await writeRecord('a2', 'start=20\n'); // 无注释行

      const sync = MpvWatchLaterSync();
      expect(
        await sync.readStartSeconds(dir, 'http://host/target.mp4'),
        isNull,
      );
    });

    test('目录不存在返回 null', () async {
      const sync = MpvWatchLaterSync();
      expect(
        await sync.readStartSeconds(
          Directory('${dir.path}${Platform.pathSeparator}missing'),
          'http://h/x.mp4',
        ),
        isNull,
      );
    });

    test('deleteRecord 同时删除 MD5 与注释匹配记录', () async {
      const url = 'http://host/dav/delete.mp4';
      final md5File = File(
        '${dir.path}${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(url)}',
      )..writeAsStringSync('start=30\n');
      final namedFile = File('${dir.path}${Platform.pathSeparator}named-record')
        ..writeAsStringSync('# $url\nstart=40\n');

      await const MpvWatchLaterSync().deleteRecord(dir, url);

      expect(md5File.existsSync(), isFalse);
      expect(namedFile.existsSync(), isFalse);
    });
  });
}
