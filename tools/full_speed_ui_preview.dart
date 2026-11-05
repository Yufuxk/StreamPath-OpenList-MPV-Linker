import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:win32/win32.dart' as win32;

import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/film_fast_task.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_fast_task_ui.dart';
import 'package:streampath/presentation/widgets/window_title_bar.dart';

/// 隔离原生预览只使用内存数据库和合成进度，不访问正式配置或媒体来源。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await _preview();
  } catch (error, stack) {
    final output = Directory('build/full-speed-validation/native');
    await output.create(recursive: true);
    await File('${output.path}/failure.txt').writeAsString('$error\n$stack');
  } finally {
    await const MethodChannel(
      'streampath/appearance',
    ).invokeMethod<void>('close');
  }
}

Future<void> _preview() async {
  final output = Directory('build/full-speed-validation/native');
  await output.create(recursive: true);
  final store = await FilmCatalogStore.open(inMemoryDatabasePath);
  final tmdb = TmdbMetadataService();
  final catalog = FilmCatalogController(
    store: store,
    tmdb: tmdb,
    images: FilmCatalogImageCache(Directory('${output.path}/images'), tmdb),
    sourceFor: (_) => throw StateError('Preview cannot access media sources'),
  );
  catalog.fastTaskState.value = const FilmFastTask(
    id: 1,
    status: 'running',
    scrapeOnly: false,
    incremental: false,
    createdAt: 0,
    elapsedMs: 12500,
    directories: 129,
    discoveredDirectories: 300,
    files: 4200,
    processed: 1280,
    total: 4200,
    matched: 1200,
    path: 'Movies/Example/Season 01/Episode 01',
  );
  final scenario = ValueNotifier((AppLanguage.simplifiedChinese, false));
  final boundaryKey = GlobalKey();
  final catalogFuture = Future.value(catalog);
  const channel = MethodChannel('streampath/appearance');
  runApp(
    ValueListenableBuilder(
      valueListenable: scenario,
      builder: (context, value, _) => MaterialApp(
        locale: value.$1.locale,
        supportedLocales: AppLanguage.values.map((value) => value.locale),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: value.$2 ? AppTheme.dark(glass: true) : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.8)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: boundaryKey,
          child: Scaffold(
            body: Column(
              children: [
                WindowTitleBar(
                  taskLocked: true,
                  onCloseRequested: catalog.close,
                ),
                Expanded(child: FilmFastTaskProgress(catalog: catalogFuture)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 700));
  final className = 'StreamPath.MainWindow'.toNativeUtf16();
  final window = win32.FindWindow(className, nullptr);
  calloc.free(className);
  final owner = calloc<Uint32>();
  win32.GetWindowThreadProcessId(window, owner);
  final owned = window != 0 && owner.value == win32.GetCurrentProcessId();
  calloc.free(owner);
  if (!owned) throw StateError('Preview window ownership mismatch');
  final evidence = <Map<String, Object>>[];
  for (final language in AppLanguage.values) {
    for (final glass in [false, true]) {
      scenario.value = (language, glass);
      await channel.invokeMethod<void>('setTaskLocked', false);
      win32.SetWindowPos(
        window,
        0,
        100,
        100,
        900,
        800,
        win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
      );
      await channel.invokeMethod<void>('setTaskLocked', true);
      final before = calloc<win32.RECT>();
      final after = calloc<win32.RECT>();
      try {
        win32.GetWindowRect(window, before);
        win32.SendMessage(window, win32.WM_SYSCOMMAND, win32.SC_MAXIMIZE, 0);
        win32.SendMessage(window, win32.WM_SYSCOMMAND, win32.SC_MINIMIZE, 0);
        win32.SetWindowPos(
          window,
          0,
          150,
          150,
          600,
          500,
          win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
        );
        win32.GetWindowRect(window, after);
        if (before.ref.left != after.ref.left ||
            before.ref.top != after.ref.top ||
            before.ref.right != after.ref.right ||
            before.ref.bottom != after.ref.bottom) {
          throw StateError('Task lock allowed window movement or resizing');
        }
      } finally {
        calloc.free(before);
        calloc.free(after);
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await WidgetsBinding.instance.endOfFrame;
      final image =
          await (boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File(
        '${output.path}/${language.name}-${glass ? 'glass' : 'light'}.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      evidence.add({
        'language': language.name,
        'glassTheme': glass,
        'windowLock': true,
      });
    }
  }
  await File('${output.path}/result.json').writeAsString(jsonEncode(evidence));
}
