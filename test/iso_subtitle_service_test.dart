import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/iso_subtitle_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_directory_entry.dart';
import 'package:streampath/domain/services/iso_subtitle_service.dart';
import 'package:streampath/domain/services/local_media_source.dart';

void main() {
  late Directory root;
  late LocalMediaSource source;
  late IsoSubtitleStore store;
  Future<void> write(String path, [List<int> bytes = const [1, 2, 3]]) async {
    final file = File(p.join(root.path, path));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  Future<IsoSubtitleContext> discover() async {
    final entries = await source.fetchDirectory('', forceRefresh: true);
    final iso = entries.firstWhere((e) => e.name == 'Anime.iso');
    final context = IsoSubtitleContext(
      source: source,
      iso: iso,
      isoPath: 'Anime.iso',
      store: store,
    );
    await context.discover();
    return context;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('iso-subtitles-');
    source = LocalMediaSource(
      await LocalRootConfig.fromDirectory(
        path: root.path,
        displayName: 'test',
        rootId: 'test-iso-root',
      ),
    );
    store = IsoSubtitleStore(Directory(p.join(root.path, 'maps')));
    await write('Anime.iso');
  });
  tearDown(() async => root.delete(recursive: true));

  test('只采集直属字幕；未获得节目表前不把集数写成 MPLS 绑定', () async {
    await write('01.ass');
    await write('Subs/02.srt');
    await write('Subs/Nested/03.ass');
    await write('Other/04.ass');
    await write('Subs/raw.sup');
    final context = await discover();
    expect(context.candidates.map((c) => c.path), ['01.ass', 'Subs/02.srt']);
    expect(context.effective, isEmpty);
  });
  test('单 ISO 显式 MPLS 自动匹配；多个格式选最高分', () async {
    await write('Subs/mpls00003.chs.ass');
    await write('Anime.mpls00004.ass');
    await write('Anime.mpls00004.srt');
    final context = await discover();
    expect(context.effective, {
      '00003': 'Subs/mpls00003.chs.ass',
      '00004': 'Anime.mpls00004.ass',
    });
  });
  test('同目录多 ISO 不共享裸 MPLS 绑定', () async {
    await write('Other.iso');
    await write('mpls00003.ass');
    await write('Anime.mpls00004.ass');
    expect((await discover()).effective, {'00004': 'Anime.mpls00004.ass'});
  });
  test('未打开字幕面板也能按视频时长准备自动候选，禁用写入会话配置', () async {
    await write(
      'first.chs.srt',
      utf8.encode('1\n00:00:01,000 --> 00:23:20,000\nOne'),
    );
    await write(
      'second.en.srt',
      utf8.encode('1\n00:00:01,000 --> 00:25:00,000\nTwo'),
    );
    final context = await discover();
    context.titleCatalog = [
      {'id': '00003', 'duration': 1400},
      {'id': '00009', 'duration': 1500},
    ];
    expect(context.effective['00009'], 'second.en.srt');
    await context.bind('00009', null);
    final session = await context.prepare(
      Directory(p.join(root.path, 'scored')),
      sessionId: 'scored',
      pipeName: 'pipe',
      menu: true,
      autoSelect: false,
    );
    expect(session.localBindings.containsKey('00009'), isFalse);
    expect(
      session.localBindings['candidate:second.en.srt'],
      p.join(root.path, 'second.en.srt'),
    );
    final line = (await File(session.scriptPath!).readAsLines()).first;
    final config =
        jsonDecode(
              jsonDecode(line.substring('local CONFIG_JSON = '.length))
                  as String,
            )
            as Map;
    expect(config['select'], isFalse);
    expect(config['overrides'], ['00009']);
    expect(config['titles'], context.titleCatalog);
    expect((config['candidates'] as List).last['duration'], 1500);
  });
  test('用户禁用优先于自动建议，保存绑定跨次复用', () async {
    await write('mpls00003.ass');
    await write('Subs/03.srt');
    var context = await discover();
    await context.bind('00003', null);
    expect((await discover()).effective, isEmpty);
    await context.bind('00003', 'Subs/03.srt');
    context = await discover();
    expect(context.effective, {'00003': 'Subs/03.srt'});
    await context.bind('00003', null, automatic: true);
    expect(context.effective, {'00003': 'mpls00003.ass'});
  });
  test('ISO 信息变化暂停旧映射；坏文件不会被保存覆盖', () async {
    await write('03.ass');
    var context = await discover();
    await context.bind('00003', '03.ass');
    await write('Anime.iso', [1, 2, 3, 4]);
    context = await discover();
    expect(context.changed, isTrue);
    expect(context.effective, isEmpty);
    final file = File(p.join(store.directory.path, '${context.key}.json'));
    await file.writeAsString('{invalid');
    context = await discover();
    expect(context.writable, isFalse);
    await expectLater(context.bind('00003', '03.ass'), throwsFormatException);
    expect(await file.readAsString(), '{invalid');
  });
  test('本地使用源字幕路径，只复制直属字体且保持字节', () async {
    await write('Anime.mpls00003.ass', [0xff, 0xfe, 65, 0]);
    await write('Fonts/Test.ttf', [1, 9, 3]);
    await write('Fonts/Nested/Other.ttf');
    final context = await discover();
    final sessionDir = Directory(p.join(root.path, 'session'));
    final session = await context.prepare(
      sessionDir,
      sessionId: 'test',
      pipeName: 'test',
      menu: false,
      autoSelect: true,
    );
    expect(
      session.localBindings['00003'],
      p.join(root.path, 'Anime.mpls00003.ass'),
    );
    expect(context.fonts.length, 1);
    final copied = File(
      p.join(sessionDir.path, 'streampath-fonts-test', '0.ttf'),
    );
    expect(await copied.readAsBytes(), [1, 9, 3]);
    expect(await File(p.join(root.path, 'Anime.mpls00003.ass')).readAsBytes(), [
      0xff,
      0xfe,
      65,
      0,
    ]);
    final saved = await File(
      p.join(sessionDir.path, 'iso-subtitle-session.json'),
    ).readAsString();
    expect(jsonDecode(saved)['key'], context.key);
  });
  test('坏路径不能通过用户绑定持久化', () async {
    final context = await discover();
    await expectLater(
      context.bind('00001', '../escape.ass'),
      throwsFormatException,
    );
    expect(
      () => store.update(
        context.key,
        context.revision,
        '00001',
        'https://secret/a.ass',
      ),
      throwsArgumentError,
    );
    expect(
      () => IsoSubtitleContext.relativePath(
        source,
        const LocalMediaEntry(
          name: 'a.ass',
          relativePath: '../a.ass',
          absolutePath: 'C:/a.ass',
          isDirectory: false,
        ),
      ),
      throwsFormatException,
    );
  });
  test('同一 ISO 两个上下文同时保存不同节目不会丢失另一条绑定', () async {
    await write('01.ass');
    await write('02.ass');
    final first = await discover(), second = await discover();
    await Future.wait([
      first.bind('00001', '01.ass'),
      second.bind('00002', '02.ass'),
    ]);
    expect((await discover()).effective, {
      '00001': '01.ass',
      '00002': '02.ass',
    });
  });
}
