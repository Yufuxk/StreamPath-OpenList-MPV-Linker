import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/iso_subtitle_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/local_iso_service.dart';
import 'package:streampath/domain/services/disc_programme.dart';
import 'package:streampath/domain/services/iso_access_provider.dart';
import 'package:streampath/domain/services/iso_player_arguments.dart';
import 'package:streampath/domain/services/iso_playback_service.dart';
import 'package:streampath/domain/services/iso_subtitle_matcher.dart';

void main() {
  test('本地 DVD 文件 URI 与原路径使用相同身份，保留文件名中的井号', () {
    const path = r'C:\DVD\Disc#01.iso';
    final raw = IsoPlaybackService.libraryKey(
      profileId: 'local:test',
      resolvedUrl: path,
    );
    final encoded = IsoPlaybackService.libraryKey(
      profileId: 'local:test',
      resolvedUrl: Uri.file(path, windows: true).toString(),
    );
    expect(raw, encoded);
    final source = LocalIsoService(
      LocalMediaSource(
        const LocalRootConfig(
          rootId: 'test',
          displayName: 'DVD',
          path: r'C:\DVD',
        ),
      ),
    );
    expect(
      source.persistentUrl('Disc#01.iso'),
      Uri.file(path, windows: true).toString(),
    );
    expect(
      source.persistentUrl('http://127.0.0.1/Disc%2301.iso'),
      source.persistentUrl('Disc#01.iso'),
    );
    expect(
      source.persistentUrl('100%.iso'),
      Uri.file(r'C:\DVD\100%.iso', windows: true).toString(),
    );
    expect(
      raw,
      isNot(
        IsoPlaybackService.libraryKey(
          profileId: 'local:test',
          resolvedUrl: r'C:\DVD\Disc#02.iso',
        ),
      ),
    );
  });
  test('DVD 标题身份、显示与续播和 MPLS 隔离', () {
    expect(isDvdProgramme('dvd-title-01'), isTrue);
    expect(isDiscProgramme('00001'), isTrue);
    expect(isDiscProgramme('dvd-title-00'), isFalse);
    expect(isDiscProgramme('dvd-title-100'), isFalse);
    expect(discProgrammeResumeId('00001'), 'bd://mpls/00001');
    expect(discProgrammeResumeId('dvd-title-01'), 'dvd-title://01');
    expect(discProgrammeLabel('dvd-title-02'), 'Title 02');
  });

  test('DVD ready 不伪造 MPLS，盘种与身份必须一致', () {
    final message = <String, dynamic>{
      'type': 'ready',
      'version': 1,
      'port': 12345,
      'token': '0123456789abcdef0123456789abcdef',
      'totalBytes': 4096,
      'discType': 'dvd',
      'unavailableDvdTitles': [3],
      'titles': [
        <String, dynamic>{
          'titleIndex': 0,
          'programmeId': 'dvd-title-01',
          'durationMs': 1000,
          'size': 2048,
          'chapters': [],
        },
      ],
    };
    final ready = IsoBridgeReady.fromMessage(message);
    expect(ready.discType, DiscType.dvd);
    expect(ready.unavailableDvdTitles, [3]);
    expect(ready.titles.single.programmeId, 'dvd-title-01');
    expect(
      () => IsoBridgeReady.fromMessage({...message, 'discType': 'bluray'}),
      throwsException,
    );
    expect(
      () => IsoBridgeReady.fromMessage({...message, 'discType': 'unknown'}),
      throwsException,
    );
    expect(
      IsoBridgeReady.fromMessage({
        ...message,
        'titles': [],
      }, detectOnly: true).titles,
      isEmpty,
    );
  });

  test('TITLE 明确匹配、多 ISO 前缀和 MPLS 互不误匹配', () {
    Map<String, dynamic>? candidate(String name, int count) =>
        IsoSubtitleMatcher.describe(name, 'disc', count);
    expect(candidate('TITLE01.chs.ass', 1)?['programmeId'], 'dvd-title-01');
    expect(candidate('TITLE01.chs.ass', 2), isNull);
    final dvd = candidate('Disc.TITLE02.chs.ass', 2)!;
    expect(dvd['programmeId'], 'dvd-title-02');
    expect(IsoSubtitleMatcher.best('dvd-title-01', [], [dvd]), isNull);
    expect(IsoSubtitleMatcher.best('00002', [], [dvd]), isNull);
    expect(IsoSubtitleMatcher.best('dvd-title-02', [], [dvd]), dvd['path']);
    expect(candidate('Disc.TITLE00.chs.ass', 1), isNull);
    expect(candidate('Disc.TITLE100.chs.ass', 1), isNull);
  });

  test('DVD 手动字幕与禁用可持久化，蓝光旧绑定仍可读', () async {
    final directory = await Directory.systemTemp.createTemp(
      'dvd-subtitle-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = IsoSubtitleStore(directory);
    final key = 'a' * 64;
    await store.update(
      key,
      'revision1',
      'dvd-title-01',
      'Disc.TITLE01.chs.ass',
    );
    expect(
      (await store.load(key, 'revision1')).bindings['dvd-title-01'],
      'Disc.TITLE01.chs.ass',
    );
    expect((await store.load(key, 'revision2')).changed, isTrue);
    await store.update(key, 'revision1', 'dvd-title-01', null);
    expect((await store.load(key, 'revision1')).bindings, {
      'dvd-title-01': null,
    });
    await File('${directory.path}/${'b' * 64}.json').writeAsString(
      '{"version":1,"revision":"old","bindings":{"00001":"old.ass"}}',
    );
    expect((await store.load('b' * 64, 'old')).bindings, {'00001': 'old.ass'});
  });

  test('标题流启动参数清除原生 DVD 选项和设备路径', () {
    expect(
      filterIsoPlayerArguments([
        '--dvd-device',
        r'C:\disc.iso',
        '--dvd-angle=2',
        'dvd://1',
        'dvdnav://2',
        '--volume=50',
      ]),
      ['--volume=50'],
    );
  });
}
