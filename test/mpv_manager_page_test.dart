import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/features/mpv_manager/mpv_document.dart';
import 'package:streampath/features/mpv_manager/mpv_file_store.dart';
import 'package:streampath/features/mpv_manager/mpv_installation.dart';
import 'package:streampath/features/mpv_manager/mpv_manager_page.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/localization/mpv_manager_translations.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_segmented_control.dart';
import 'package:streampath/presentation/widgets/section_switcher.dart';

import 'helpers/pump_until.dart';

void main() {
  setUpAll(() async {
    for (final entry in {
      'Segoe UI': 'segoeui.ttf',
      'Roboto': 'segoeui.ttf',
      'Microsoft YaHei': 'msyh.ttc',
      'Segoe MDL2 Assets': 'segmdl2.ttf',
      'Segoe Fluent Icons': 'SegoeIcons.ttf',
    }.entries) {
      final file = File('C:/Windows/Fonts/${entry.value}');
      if (file.existsSync()) {
        await (FontLoader(entry.key)..addFont(
              Future.value(ByteData.sublistView(file.readAsBytesSync())),
            ))
            .load();
      }
    }
  });
  late Directory temp;
  late MpvFileStore store;
  late MpvInstallationContext installation;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('mpv_manager_page_');
    store = MpvFileStore(p.join(temp.path, 'history'));
    final conf = File(p.join(temp.path, 'mpv.conf'))
      ..writeAsStringSync('# keep\r\nvolume = 20 # keep\r\n[anime]\nvo=gpu');
    final input = File(p.join(temp.path, 'input.conf'))
      ..writeAsStringSync('a seek 2\n');
    final script = File(p.join(temp.path, 'test.lua'))
      ..writeAsStringSync('return 1');
    final opts = File(p.join(temp.path, 'test.conf'))
      ..writeAsStringSync('enabled=yes');
    final shader = File(p.join(temp.path, 'test.glsl'))
      ..writeAsStringSync('//!HOOK MAIN\nvec4 hook(){return vec4(0);}');
    installation = MpvInstallationContext(
      'mpv.exe',
      [temp.path],
      [
        MpvManagedFile(conf.path, MpvDocumentKind.options, 'mpv.conf'),
        MpvManagedFile(input.path, MpvDocumentKind.input, 'input.conf'),
        MpvManagedFile(opts.path, MpvDocumentKind.scriptOptions, 'script-opts'),
      ],
      [MpvLocalScript(script.path, script.path, true, false, opts.path)],
      [shader.path],
      false,
      [],
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> open(
    WidgetTester tester,
    AppLanguage language, {
    bool narrow = false,
    bool glass = false,
    Size? size,
    double? textScale,
    bool disableAnimations = false,
  }) async {
    tester.view.physicalSize =
        size ?? (narrow ? const Size(600, 900) : const Size(1280, 900));
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: language.locale,
        supportedLocales: AppLanguage.values.map((e) => e.locale),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: narrow
            ? AppTheme.light(glass: glass)
            : AppTheme.dark(glass: glass),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
            textScaler: TextScaler.linear(textScale ?? (narrow ? 1.6 : 1)),
          ),
          child: child!,
        ),
        home: RepaintBoundary(
          key: const Key('preview'),
          child: MpvManagerPage(
            player: const PlayerConfig(name: 'mpv', executable: 'mpv'),
            store: store,
            initialInstallation: installation,
          ),
        ),
      ),
    );
    await pumpUntil(
      tester,
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      reason: 'Manager should load local fixtures.',
    );
    await tester.pumpAndSettle();
  }

  test('every manager string has all four languages', () {
    for (final entry in mpvManagerTranslations.entries) {
      expect(entry.value, hasLength(3), reason: entry.key);
      for (final language in AppLanguage.values.skip(1)) {
        expect(
          AppLocalizations(language).text(entry.key),
          entry.value[language.index - 1],
        );
      }
    }
    final source = File(
      'lib/features/mpv_manager/mpv_manager_page.dart',
    ).readAsStringSync();
    final missing = <String>{};
    for (final match in RegExp(
      r"'([^'\r\n]*[\u4e00-\u9fff][^'\r\n]*)'",
    ).allMatches(source)) {
      final label = match[1]!;
      if (label.contains(r'${') || label.contains(r'\u')) continue;
      if (AppLocalizations(
        AppLanguage.english,
      ).text(label).contains(RegExp(r'[\u4e00-\u9fff]'))) {
        missing.add(label);
      }
    }
    expect(missing, isEmpty);
  });

  for (final language in AppLanguage.values) {
    for (final narrow in [false, true]) {
      testWidgets('manager layout ${language.name} narrow=$narrow', (
        tester,
      ) async {
        await open(tester, language, narrow: narrow);
        final l10n = AppLocalizations(language);
        for (final label in ['MPV 参数', '快捷键', '本地插件', '着色器', '更改记录', '概览']) {
          await tester.ensureVisible(find.text(l10n.text(label)).first);
          await tester.tap(find.text(l10n.text(label)).first);
          await tester.pump();
          await pumpUntil(
            tester,
            () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
            reason: 'Tab should be available.',
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '$label ${language.name}',
          );
        }
        if (language == AppLanguage.english && !narrow) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('preview')),
            );
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = File('build/mpv-manager-ui/overview-en.png');
            output.parent.createSync(recursive: true);
            output.writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }

  for (final language in AppLanguage.values) {
    for (final narrow in [false, true]) {
      testWidgets(
        'all manager tabs keep labels outside fields ${language.name} narrow=$narrow',
        (tester) async {
          await open(
            tester,
            language,
            glass: true,
            narrow: narrow,
            size: narrow ? const Size(600, 760) : const Size(1920, 1080),
          );
          final l10n = AppLocalizations(language);
          for (final label in ['MPV 参数', '快捷键', '本地插件', '着色器', '更改记录', '概览']) {
            await tester.ensureVisible(find.text(l10n.text(label)).first);
            await tester.tap(find.text(l10n.text(label)).first);
            await tester.pump();
            await pumpUntil(
              tester,
              () =>
                  !['MPV 参数', '快捷键', '本地插件', '着色器'].contains(label) ||
                  find
                      .text(
                        p.join(
                          temp.path,
                          label == '快捷键'
                              ? 'input.conf'
                              : label == '本地插件'
                              ? 'test.conf'
                              : 'mpv.conf',
                        ),
                      )
                      .evaluate()
                      .isNotEmpty,
              reason: 'Editor should finish reading its file.',
            );
            await tester.pumpAndSettle();
            final navigation = find.byWidgetPredicate(
              (widget) => widget is FilmSegmentedControl,
            );
            final navigationRect = tester.getRect(navigation);
            for (final tabLabel in [
              '概览',
              'MPV 参数',
              '快捷键',
              '本地插件',
              '着色器',
              '更改记录',
            ]) {
              final title = find.descendant(
                of: navigation,
                matching: find.text(l10n.text(tabLabel)),
              );
              final button = find
                  .ancestor(of: title, matching: find.byType(TextButton))
                  .first;
              final titleRect = tester.getRect(title);
              final buttonRect = tester.getRect(button);
              expect(titleRect.center.dx, closeTo(buttonRect.center.dx, .5));
              expect(titleRect.center.dy, closeTo(buttonRect.center.dy, .5));
              expect(
                titleRect.center.dy,
                closeTo(navigationRect.center.dy, .5),
              );
              expect(tester.widget<Text>(title).style?.fontSize, 14);
              expect(tester.widget<Text>(title).style?.fontFamily, isNotNull);
            }
            final selectedButton = find
                .ancestor(
                  of: find.descendant(
                    of: navigation,
                    matching: find.text(l10n.text(label)),
                  ),
                  matching: find.byType(TextButton),
                )
                .first;
            final selection = find.descendant(
              of: navigation,
              matching: find.byType(FractionallySizedBox),
            );
            expect(
              tester.getCenter(selection).dx,
              closeTo(tester.getCenter(selectedButton).dx, .5),
            );
            expect(
              tester.getCenter(selection).dy,
              closeTo(navigationRect.center.dy, .5),
            );
            for (final field in tester.widgetList<InputDecorator>(
              find.byType(InputDecorator),
            )) {
              expect(
                field.decoration.labelText,
                isNull,
                reason: 'Floating labels must not overlap surrounding content.',
              );
            }
            for (final card in tester.renderObjectList<RenderBox>(
              find.byType(Card),
            )) {
              expect(card.size.width, lessThanOrEqualTo(1200));
            }
            if (label == 'MPV 参数' || label == '快捷键') {
              final keyField = find.widgetWithText(
                TextField,
                label == 'MPV 参数' ? '20' : 'seek 2',
              );
              final caption = find.text(
                l10n.text(label == 'MPV 参数' ? '参数值' : '命令'),
              );
              await tester.scrollUntilVisible(
                keyField,
                160,
                scrollable: find
                    .byWidgetPredicate(
                      (widget) =>
                          widget is Scrollable &&
                          widget.axisDirection == AxisDirection.down,
                    )
                    .first,
              );
              await tester.pumpAndSettle();
              if (narrow) {
                expect(
                  tester.getRect(caption).bottom,
                  lessThanOrEqualTo(tester.getRect(keyField).top - 7),
                );
              }
            }
            if (label == '着色器') {
              expect(find.text(l10n.text('参数分类')), findsNothing);
              expect(find.text(l10n.text('搜索参数、按键或命令')), findsNothing);
            }
            expect(
              tester.takeException(),
              isNull,
              reason: '$label ${language.name}',
            );
          }
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    }
    testWidgets('manager dialogs keep fields readable ${language.name}', (
      tester,
    ) async {
      final doc = await tester.runAsync(
        () =>
            store.load(p.join(temp.path, 'mpv.conf'), MpvDocumentKind.options),
      );
      await tester.runAsync(
        () => store.commit(doc!, doc.setValue(doc.entries.first, '21')),
      );
      await open(
        tester,
        language,
        glass: true,
        size: const Size(720, 700),
        textScale: 1.6,
      );
      final l10n = AppLocalizations(language);
      Future<void> click(String text) async {
        final finder = find.text(l10n.text(text)).first;
        await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await click('MPV 参数');
      await pumpUntil(
        tester,
        () => find.text(l10n.text('新增项目')).evaluate().isNotEmpty,
        reason: 'Options should load.',
      );
      await click('新增项目');
      for (final field in tester.widgetList<InputDecorator>(
        find.byType(InputDecorator),
      )) {
        expect(field.decoration.labelText, isNull);
      }
      expect(tester.takeException(), isNull);
      await click('取消');
      await tester.scrollUntilVisible(
        find.text(l10n.text('修改名称')),
        160,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await click('修改名称');
      for (final field in tester.widgetList<InputDecorator>(
        find.byType(InputDecorator),
      )) {
        expect(field.decoration.labelText, isNull);
      }
      expect(tester.takeException(), isNull);
      await click('取消');
      await click('源码');
      await pumpUntil(
        tester,
        () => find.byType(Dialog).evaluate().isNotEmpty,
        reason: 'Source dialog should finish reading the file.',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await click('取消');
      await click('更改记录');
      await click('查看差异');
      expect(tester.takeException(), isNull);
      await click('关闭');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
    'completed value edits persist precisely without restarting playback',
    (tester) async {
      await open(tester, AppLanguage.english);
      await tester.tap(find.text('MPV options'));
      await pumpUntil(
        tester,
        () => find.widgetWithText(TextField, '20').evaluate().isNotEmpty,
        reason: 'Option editor should load.',
      );
      final valueField = find.widgetWithText(TextField, '20');
      await tester.enterText(valueField, '35');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await pumpUntil(
        tester,
        () => File(
          p.join(temp.path, 'mpv.conf'),
        ).readAsStringSync().contains('volume = 35'),
        reason: 'Completed value should save.',
      );
      expect(
        File(p.join(temp.path, 'mpv.conf')).readAsStringSync(),
        '# keep\r\nvolume = 35 # keep\r\n[anime]\nvo=gpu',
      );
      expect(await tester.runAsync(store.history), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'manager uses shared transitions and only opens the final queued tab',
    (tester) async {
      final recording = _RecordingStore(p.join(temp.path, 'history'));
      store = recording;
      await open(tester, AppLanguage.english);
      final switcherFinder = find.byWidgetPredicate(
        (widget) => widget is StreamPathSectionSwitcher,
      );
      final switcher = tester.widget<StreamPathSectionSwitcher<dynamic>>(
        switcherFinder,
      );
      await tester.tap(find.text('MPV options'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(recording.paths, isEmpty);
      final slide = find.byWidgetPredicate(
        (widget) =>
            widget is Transform &&
            widget.key is ValueKey &&
            (widget.key as ValueKey).value ==
                ('section-slide', switcher.order[1]),
      );
      final incoming = tester.widget<Transform>(slide);
      expect(incoming.transform.storage[12], inExclusiveRange(0, 30));
      expect(find.text('Add entry'), findsNothing);
      await tester.tap(find.text('Shortcuts'));
      await tester.pump();
      await tester.tap(find.text('Changes'));
      await tester.pumpAndSettle();
      expect(find.text('No changes yet.'), findsOneWidget);
      expect(recording.paths, isEmpty);
      await tester.tap(find.text('MPV options'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.widget<Transform>(slide).transform.storage[12],
        inExclusiveRange(-30, 0),
      );
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () => find.widgetWithText(TextField, '20').evaluate().isNotEmpty,
        reason: 'The settled options tab should open its file.',
      );
      expect(recording.paths, [p.join(temp.path, 'mpv.conf')]);
      await tester.enterText(find.widgetWithText(TextField, '20'), '36');
      await tester.tap(find.text('Shortcuts'));
      await pumpUntil(
        tester,
        () =>
            File(
              p.join(temp.path, 'mpv.conf'),
            ).readAsStringSync().contains('volume = 36') &&
            find.widgetWithText(TextField, 'seek 2').evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
        reason:
            'Blur saving and the incoming file should finish independently.',
      );
      expect(
        File(p.join(temp.path, 'mpv.conf')).readAsStringSync(),
        '# keep\r\nvolume = 36 # keep\r\n[anime]\nvo=gpu',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('manager respects reduced motion when activating a tab', (
    tester,
  ) async {
    await open(tester, AppLanguage.english, disableAnimations: true);
    await tester.tap(find.text('Shortcuts'));
    await tester.pumpAndSettle();
    await pumpUntil(
      tester,
      () => find.widgetWithText(TextField, 'seek 2').evaluate().isNotEmpty,
      reason: 'Reduced motion should still activate the target file.',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('shortcut recording preserves Shift for function keys', (
    tester,
  ) async {
    await open(tester, AppLanguage.english);
    await tester.ensureVisible(find.text('Shortcuts'));
    await tester.tap(find.text('Shortcuts'));
    await pumpUntil(
      tester,
      () => find.text('Change key').evaluate().isNotEmpty,
      reason: 'Input editor should load.',
    );
    await tester.tap(find.text('Change key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record shortcut'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.f1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Shift+F1'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      File(p.join(temp.path, 'input.conf')).readAsStringSync(),
      'a seek 2\n',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final language in AppLanguage.values) {
    testWidgets(
      'compact input rows edit and filter menu paths ${language.name}',
      (tester) async {
        const original =
            'a seek 2 #menu: 着色器 > Anime4K > 关闭\r\n# script-message-to uosc playlist #menu: 打开 > 播放列表\r\nb cycle mute\r\n';
        final file = File(p.join(temp.path, 'input.conf'))
          ..writeAsStringSync(original);
        await open(tester, language);
        final l10n = AppLocalizations(language);
        await tester.tap(find.text(l10n.text('快捷键')));
        await tester.pump();
        await pumpUntil(
          tester,
          () => find
              .widgetWithText(TextField, '着色器 > Anime4K > 关闭')
              .evaluate()
              .isNotEmpty,
          reason: 'Menu metadata should load.',
        );
        await tester.pumpAndSettle();
        final command = find.widgetWithText(TextField, 'seek 2');
        final menu = find.widgetWithText(TextField, '着色器 > Anime4K > 关闭');
        expect(
          tester.getCenter(command).dy,
          closeTo(tester.getCenter(menu).dy, .1),
        );
        final card = find
            .ancestor(of: command, matching: find.byType(Card))
            .first;
        expect(tester.getSize(card).height, lessThan(100));
        if (language == AppLanguage.english) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('preview')),
            );
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            File(
              'build/mpv-manager-extension/compact-input-en.png',
            ).writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.enterText(menu, '视频 > 缩放');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await pumpUntil(
          tester,
          () => file.readAsStringSync().contains('视频 > 缩放'),
          reason: 'Only the menu span should save.',
        );
        expect(
          file.readAsStringSync(),
          original.replaceFirst('着色器 > Anime4K > 关闭', '视频 > 缩放'),
        );
        await pumpUntil(
          tester,
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
          reason: 'Menu save should finish before filtering.',
        );
        await tester.tap(find.text(l10n.text('全部命令')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.text('视频')).last);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'seek 2'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'cycle mute'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  for (final tab in ['MPV options', 'Shortcuts', 'Local scripts']) {
    testWidgets('newly visible $tab text is readable on the first scroll frame', (
      tester,
    ) async {
      final fileName = switch (tab) {
        'MPV options' => 'mpv.conf',
        'Shortcuts' => 'input.conf',
        _ => 'test.conf',
      };
      final content = List.generate(
        100,
        (index) => tab == 'Shortcuts'
            ? 'F${index + 1} show-text value_$index'
            : 'option_$index=value_$index',
      ).join('\n');
      File(p.join(temp.path, fileName)).writeAsStringSync(content);
      await open(tester, AppLanguage.english);
      await tester.tap(find.text(tab));
      await tester.pump();
      await pumpUntil(
        tester,
        () => find.text('Add entry').evaluate().isNotEmpty,
        reason: 'The long configuration should load.',
      );
      final page = tester
          .widget<ListView>(find.byType(ListView).first)
          .controller!;
      final viewport = tester.getRect(find.byType(ListView).first);
      var inspected = 0;
      for (final offset in [1600.0, 3200.0, 4800.0, 2400.0, 800.0]) {
        page.jumpTo(offset);
        await tester.pump();
        for (final state in tester.stateList<EditableTextState>(
          find.byType(EditableText),
        )) {
          final render = state.renderEditable;
          final text = render.text!.toPlainText();
          if (!text.contains(RegExp(r'(option_|value_|^F\d)'))) continue;
          final rect = render.localToGlobal(Offset.zero) & render.size;
          if (!rect.overlaps(viewport)) continue;
          inspected++;
          expect(
            render.offset.pixels,
            closeTo(0, .01),
            reason:
                '$tab $text must be visible immediately at page offset $offset.',
          );
        }
        expect(tester.takeException(), isNull);
      }
      expect(inspected, greaterThan(15));
      expect(File(p.join(temp.path, fileName)).readAsStringSync(), content);
      expect(await tester.runAsync(store.history), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('adding a shader keeps the original profile and comments', (
    tester,
  ) async {
    await open(tester, AppLanguage.english);
    await tester.ensureVisible(find.text('Shaders'));
    await tester.tap(find.text('Shaders'));
    await pumpUntil(
      tester,
      () => find.text('Add to selected scope').evaluate().isNotEmpty,
      reason: 'Shader editor should load.',
    );
    await tester.ensureVisible(find.text('Add to selected scope'));
    await tester.tap(find.text('Add to selected scope'));
    await pumpUntil(
      tester,
      () => File(
        p.join(temp.path, 'mpv.conf'),
      ).readAsStringSync().contains('glsl-shader='),
      reason: 'Shader reference should save.',
    );
    expect(
      File(p.join(temp.path, 'mpv.conf')).readAsStringSync(),
      '# keep\r\nvolume = 20 # keep\r\nglsl-shader=${p.join(temp.path, 'test.glsl')}\r\n[anime]\nvo=gpu',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}

class _RecordingStore extends MpvFileStore {
  _RecordingStore(super.historyDirectory);
  final paths = <String>[];
  @override
  Future<MpvDocumentSnapshot> load(String path, MpvDocumentKind kind) {
    paths.add(path);
    return super.load(path, kind);
  }
}
