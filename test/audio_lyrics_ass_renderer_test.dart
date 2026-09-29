import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/audio_media_entry.dart';
import 'package:streampath/domain/services/audio_lyrics_ass_renderer.dart';
import 'package:streampath/domain/services/audio_lyrics_localizer.dart';

void main() {
  const renderer = AudioLyricsAssRenderer();

  test('逐行 LRC 产生滚动 ASS，未制造逐字高亮', () {
    final ass = renderer.render('[00:01.00]第一行\n[00:02.50]第二行');
    expect(ass, contains('Dialogue: 0,0:00:01.00,0:00:02.50,Current'));
    expect(ass, contains(r'\move(640,384,640,360,0,300)'));
    expect(ass, isNot(contains(r'\kf')));
  });

  test('增强型与行内逐字时间戳生成原文高亮和两行辅助文本', () {
    final enhanced = renderer.render(
      '[00:01.00]<00:01.00>君<00:01.30>が<00:01.60>\n'
      '[00:01.00]ki mi ga\n'
      '[00:01.00]你\n'
      '[00:02.00]下一行',
    )!;
    expect(enhanced, contains(r'{\kf30}君'));
    expect(enhanced, contains(r'{\kf30}が'));
    expect(enhanced, contains('Auxiliary,,0,0,0,,{'));
    expect(enhanced, contains('ki mi ga'));
    expect(enhanced, contains('你'));
    expect(enhanced, isNot(contains('<00:01.30>')));

    final inline = renderer.render(
      '[00:01.00]君[00:01.30]が[00:01.60]\n[00:02.00]次',
    )!;
    expect(inline, contains(r'{\kf30}君'));
    expect(inline, contains(r'{\kf30}が'));
    expect(inline, isNot(contains('[00:01.30]')));
  });

  test('每句按辅助行数紧凑排版，上一句和下一句与当前歌词块等距', () {
    final ass = renderer.render(
      '[00:00.00]开头\n'
      '[00:01.00]原文甲\n[00:01.00]roman\n[00:01.00]翻译甲\n'
      '[00:02.00]原文乙\n[00:02.00]翻译乙\n'
      '[00:03.00]原文丙\n[00:04.00]结尾',
    )!;

    List<int> positions(String start, String style) => ass
        .split('\n')
        .where(
          (line) =>
              line.startsWith('Dialogue: 0,$start,') &&
              line.contains(',$style,,'),
        )
        .map((line) {
          final match = RegExp(
            r'move\(640,\d+,640,(\d+),0,300\)',
          ).firstMatch(line);
          expect(match, isNotNull);
          return int.parse(match!.group(1)!);
        })
        .toList();

    for (final (start, auxiliaryCount) in [
      ('0:00:01.00', 2),
      ('0:00:02.00', 1),
      ('0:00:03.00', 0),
    ]) {
      final main = positions(start, 'Current').single;
      final auxiliary = positions(start, 'Auxiliary');
      final context = positions(start, 'Context');
      expect(auxiliary, hasLength(auxiliaryCount));
      expect(context, hasLength(2));
      if (auxiliary.isNotEmpty) {
        expect(auxiliary.first - main, 48);
        if (auxiliary.length == 2) {
          expect(auxiliary.last - auxiliary.first, 36);
        }
      }
      final top = main - 24;
      final bottom = auxiliary.isEmpty ? main + 24 : auxiliary.last + 15;
      expect((top + bottom) / 2, closeTo(360, 0.5));
      expect(top - (context.first + 15), 75);
      expect((context.last - 15) - bottom, 75);
    }
  });

  test('字体、描边和整体透明度应用于所有歌词行及逐字高亮', () {
    final ass = renderer.render(
      '[00:01.00]<00:01.20>你<00:01.50>好\n[00:02.00]下一行',
      fontFamily: 'Noto Sans CJK JP',
      outlineWidth: 3.5,
      transparency: 0.4,
    )!;
    expect(ass, contains('Style: Current,Noto Sans CJK JP,48,&H66FFFFFF'));
    expect(ass, contains('Style: Auxiliary,Noto Sans CJK JP,30,&H66DDDDDD'));
    expect(ass, contains('Style: Context,Noto Sans CJK JP,30,&H66999999'));
    expect(ass, contains('&HB3000000'));
    expect(ass, contains(',1,3.5,1,5,'));
    expect(ass, contains(r'{\1a&H66&}'));
  });

  test('偏移量、BOM 与 ASS 控制字符按时间和正文处理', () {
    final ass = renderer.render(
      '\uFEFF[00:01.00]A{\\N}B\n[offset:500]\n[00:02.00]next',
    )!;
    expect(ass, contains('Dialogue: 0,0:00:00.50,0:00:01.50,Current'));
    expect(ass, contains('A｛＼N｝B'));
  });

  test('无有效时间轴时保留原 LRC', () async {
    final directory = await Directory.systemTemp.createTemp('audio_ass_');
    addTearDown(() => directory.delete(recursive: true));
    final lyrics = File('${directory.path}${Platform.pathSeparator}song.lrc');
    await lyrics.writeAsString('Only unsynchronized lyrics');
    final prepared = await renderer.prepare(
      localized: AudioLyricsLocalizationResult(
        entries: [
          AudioMediaEntry(
            url: 'song.flac',
            title: 'song',
            lyrics: AudioCompanionFile(name: 'song.lrc', url: lyrics.path),
          ),
        ],
        sessionFiles: const [],
      ),
      base: directory,
      sessionId: 'fallback',
    );
    expect(prepared.entries.single.lyrics!.url, lyrics.path);
    expect(prepared.sessionFiles, isEmpty);
  });

  test('已本地化的 UTF-8 歌词转换为会话 ASS 文件', () async {
    final directory = await Directory.systemTemp.createTemp('audio_ass_');
    addTearDown(() => directory.delete(recursive: true));
    final lyrics = File('${directory.path}${Platform.pathSeparator}song.lrc');
    await lyrics.writeAsBytes(utf8.encode('[00:01.00]歌詞'));
    final prepared = await renderer.prepare(
      localized: AudioLyricsLocalizationResult(
        entries: [
          AudioMediaEntry(
            url: 'song.flac',
            title: 'song',
            lyrics: AudioCompanionFile(name: 'song.lrc', url: lyrics.path),
          ),
        ],
        sessionFiles: [lyrics],
      ),
      base: directory,
      sessionId: 'render',
    );
    expect(prepared.entries.single.lyrics!.url, endsWith('.ass'));
    expect(prepared.sessionFiles, hasLength(2));
    expect(
      await File(prepared.entries.single.lyrics!.url).readAsString(),
      contains('歌詞'),
    );
  });
}
