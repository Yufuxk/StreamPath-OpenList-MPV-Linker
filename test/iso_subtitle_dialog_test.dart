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
  test('新增 ISO 字幕文案在三种目标语言中都有覆盖', () {
    for (final translations in [
      englishTranslations,
      japaneseTranslations,
      traditionalChineseTranslations,
    ]) {
      for (final key in [
        'ISO 外挂字幕',
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
