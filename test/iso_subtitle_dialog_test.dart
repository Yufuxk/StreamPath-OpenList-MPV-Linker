import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/iso_subtitle_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/iso_subtitle_service.dart';
import 'package:streampath/presentation/widgets/iso_subtitle_dialog.dart';
import 'package:streampath/presentation/localization/app_translation_catalog.dart';

void main() {
  testWidgets('字幕面板选择与禁用保存到同一 MPLS，关闭不影响播放入口', (tester) async {
    late Directory root;
    late IsoSubtitleContext context;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('iso-subtitle-dialog-');
      await File('${root.path}/Movie.iso').writeAsBytes([1]);
      await File('${root.path}/03.ass').writeAsBytes([1]);
      final source = LocalMediaSource(
        await LocalRootConfig.fromDirectory(
          path: root.path,
          displayName: 'test',
          rootId: 'dialog',
        ),
      );
      final files = await source.fetchDirectory('');
      context = IsoSubtitleContext(
        source: source,
        iso: files.firstWhere((e) => e.isIso),
        isoPath: 'Movie.iso',
        store: IsoSubtitleStore(Directory('${root.path}/maps')),
      );
      await context.discover();
    });
    addTearDown(() => root.delete(recursive: true));
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IsoSubtitleDialog(
            subtitles: context,
            titles: const [
              {'id': '00003', 'duration': 1500},
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('iso-subtitle-00003')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('03.ass').last);
    await tester.pump();
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(context.bindings['00003'], '03.ass');
    expect(find.text('字幕绑定已保存'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('iso-subtitle-00003')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不使用外挂字幕').last);
    await tester.pump();
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(context.bindings.containsKey('00003'), isTrue);
    expect(context.bindings['00003'], isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('候选和自动建议显示短名称，同名字幕保留不同路径值', (tester) async {
    late Directory root;
    late IsoSubtitleContext context;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('iso-subtitle-labels-');
      await File('${root.path}/Movie.iso').writeAsBytes([1]);
      await File('${root.path}/Same.ass').writeAsBytes([1]);
      final subtitleDir = Directory('${root.path}/Subtitles');
      await subtitleDir.create();
      await File('${subtitleDir.path}/Same.ass').writeAsBytes([1]);
      await File(
        '${subtitleDir.path}/Movie.mpls00003.zh.ass',
      ).writeAsBytes([1]);
      final source = LocalMediaSource(
        await LocalRootConfig.fromDirectory(
          path: root.path,
          displayName: 'test',
          rootId: 'labels',
        ),
      );
      final files = await source.fetchDirectory('');
      context = IsoSubtitleContext(
        source: source,
        iso: files.firstWhere((entry) => entry.isIso),
        isoPath: 'Movie.iso',
        store: IsoSubtitleStore(Directory('${root.path}/maps')),
      );
      await context.discover();
    });
    addTearDown(() => root.delete(recursive: true));
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IsoSubtitleDialog(
            subtitles: context,
            titles: const [
              {'id': '00003', 'duration': 3765},
              {'id': '00004', 'duration': 335},
              {'id': '00005', 'duration': 38},
              {'id': '00006', 'duration': 101},
              {'id': '00007', 'duration': 23},
            ],
          ),
        ),
      ),
    );
    expect(find.text('00003.mpls'), findsOneWidget);
    expect(find.text('1:02:45'), findsOneWidget);
    expect(find.text('自动建议：Movie.mpls00003.zh.ass'), findsOneWidget);
    final listRight = tester.getRect(find.byType(ListView).first).right;
    final selectorRight = tester
        .getRect(find.byKey(const ValueKey('iso-subtitle-00003')))
        .right;
    expect(listRight - selectorRight, greaterThanOrEqualTo(30));
    await tester.tap(find.byKey(const ValueKey('iso-subtitle-00003')));
    await tester.pumpAndSettle();
    expect(find.text('Same.ass · 根目录'), findsOneWidget);
    expect(find.text('Same.ass · Subtitles'), findsOneWidget);
    expect(find.textContaining('Subtitles/'), findsNothing);
    final option = tester.widget<DropdownMenuItem<String>>(
      find.ancestor(
        of: find.text('Same.ass · Subtitles'),
        matching: find.byType(DropdownMenuItem<String>),
      ),
    );
    expect(option.value, 'Subtitles/Same.ass');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('蓝光字幕文案在三种目标语言中都有覆盖', () {
    for (final translations in [
      englishTranslations,
      japaneseTranslations,
      traditionalChineseTranslations,
    ]) {
      for (final key in [
        'ISO 外挂字幕',
        '蓝光外挂字幕',
        '自动建议按现有规则匹配；手动选择会覆盖建议。',
        '返回标题选择',
        '蓝光内容已变化，旧绑定暂停应用；请重新确认。',
        '此会话未启用蓝光外挂字幕，请重新打开蓝光',
        '按时长、集数、名称、语言和格式综合评分；明确 MPLS 和手动绑定优先。',
        '正在准备外挂字幕…',
        '字幕绑定已保存并应用',
        '未绑定',
        '不使用外挂字幕',
        '当前节目尚不可识别或正在菜单中，自动外挂暂停。',
        '部分字幕或字体资源不可用，视频播放不受影响。',
      ]) {
        expect(translations[key], isNotNull, reason: key);
      }
    }
  });
}
