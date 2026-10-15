import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';
import 'package:streampath/presentation/widgets/sp_icons.dart';

void main() {
  final themes = [
    AppTheme.dark(),
    AppTheme.light(),
    AppTheme.dark(glass: true),
    AppTheme.light(glass: true),
  ];
  const locales = [
    Locale('zh', 'CN'),
    Locale('zh', 'TW'),
    Locale('ja'),
    Locale('en'),
  ];
  for (var mode = 0; mode < themes.length; mode++) {
    for (final locale in locales) {
      for (final scale in [1.0, 1.5]) {
        testWidgets(
          'unbounded input and toolbar: mode=$mode $locale scale=$scale',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(640, 800));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final name = TextEditingController(text: '白色相簿 WHITE ALBUM');
            addTearDown(name.dispose);
            await tester.pumpWidget(
              MaterialApp(
                theme: themes[mode],
                locale: locale,
                supportedLocales: locales,
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Builder(
                    builder: (context) => DirectoryScrollView(
                      builder: (controller) => ListView(
                        controller: controller,
                        padding: const EdgeInsets.all(24),
                        children: [
                          TextField(
                            key: const Key('plain'),
                            controller: name,
                            decoration: InputDecoration(
                              labelText: context.l10n.text('播放列表名称'),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            key: const Key('icon'),
                            decoration: InputDecoration(
                              labelText: context.l10n.text('搜索作品名称'),
                              prefixIcon: const Icon(SPIcons.search),
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            height: AppTheme.controlHeightFor(context),
                            child: TextField(
                              key: const Key('toolbar'),
                              expands: true,
                              maxLines: null,
                              decoration: InputDecoration(
                                hintText: context.l10n.text('搜索库内作品'),
                                prefixIcon: const Icon(SPIcons.search),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            for (final key in ['plain', 'icon', 'toolbar']) {
              final field = find.byKey(Key(key));
              final editable = find.descendant(
                of: field,
                matching: find.byType(EditableText),
              );
              final fieldRect = tester.getRect(field);
              final textRect = tester.getRect(editable);
              expect(fieldRect.height, greaterThanOrEqualTo(40));
              expect(textRect.top - fieldRect.top, greaterThanOrEqualTo(8));
              expect(
                fieldRect.bottom - textRect.bottom,
                greaterThanOrEqualTo(8),
              );
            }
            await tester.tap(find.byKey(const Key('plain')));
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(const Key('plain')),
              '编辑后的播放列表名称',
            );
            expect(name.text, '编辑后的播放列表名称');
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
