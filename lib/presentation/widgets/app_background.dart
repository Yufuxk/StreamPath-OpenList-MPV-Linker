import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/film_catalog_controller.dart';
import '../state/app_state.dart';
import '../theme/glass_tokens.dart';
import 'film_library_background.dart';
import 'transition_content.dart';

/// 自定义背景常驻于窗口与全部导航分支下方。
class AppBackground extends StatefulWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  State<AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<AppBackground> {
  late final Future<FilmCatalogController> _catalog;
  String? _readyPath;

  @override
  void initState() {
    super.initState();
    _catalog = context.read<AppState>().getFilmCatalog();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<FilmCatalogController>(
    future: _catalog,
    builder: (context, snapshot) {
      final catalog = snapshot.data;
      return ListenableBuilder(
        listenable: Listenable.merge([?catalog]),
        builder: (context, _) => _frame(context, catalog),
      );
    },
  );

  Widget _frame(BuildContext context, FilmCatalogController? catalog) {
    final file = catalog?.backgroundFile;
    final theme = Theme.of(context);
    final backgroundTheme = theme.copyWith(
      extensions: theme.extensions.values.map(
        (extension) => extension is GlassTokens
            ? extension.copyWith(hasCustomBackground: file != null)
            : extension,
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (file != null)
          FilmLibraryBackground(
            cache: catalog!.images,
            file: file,
            onReady: () {
              if (mounted &&
                  catalog.backgroundFile?.path == file.path &&
                  _readyPath != file.path) {
                setState(() => _readyPath = file.path);
              }
            },
          ),
        Theme(
          data: file == null
              ? backgroundTheme
              : backgroundTheme.copyWith(
                  scaffoldBackgroundColor: Colors.transparent,
                  appBarTheme: theme.appBarTheme.copyWith(
                    backgroundColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                  ),
                ),
          child: AppBackgroundScope(
            hasBackground: file != null,
            ready: file == null || _readyPath == file.path,
            child: StreamPathTransitionBackdropScope(
              hasBackdrop: file != null,
              child: widget.child,
            ),
          ),
        ),
      ],
    );
  }
}

/// 页面复用全局背景，并沿用首帧就绪门控。
class AppBackgroundScope extends InheritedWidget {
  const AppBackgroundScope({
    super.key,
    required this.hasBackground,
    required this.ready,
    required super.child,
  });

  final bool hasBackground;
  final bool ready;

  static AppBackgroundScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppBackgroundScope>();

  @override
  bool updateShouldNotify(AppBackgroundScope oldWidget) =>
      hasBackground != oldWidget.hasBackground || ready != oldWidget.ready;
}
