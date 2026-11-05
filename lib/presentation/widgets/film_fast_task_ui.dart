import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_fast_task.dart';
import '../../domain/services/film_catalog_scanner.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/glass_tokens.dart';
import 'directory_scroll_view.dart';
import 'film_directory_dialog.dart';
import 'glass_dialog.dart';
import 'sp_dialog.dart';
import 'sp_notice.dart';

const fastTaskWarning =
    '全速模式会提高并发请求和 CPU、内存、磁盘及带宽占用，可能影响系统响应。对于网盘等非您完全可控的服务器，可能触发限流、风控或账号访问限制。运行期间仅能关闭软件；关闭会保存进度并暂停任务，下次启动询问是否继续。请确认您有权访问所选来源并愿意承担这些风险。';

Future<void> runFilmFastTask(
  BuildContext context,
  FilmCatalogController catalog,
  Future<void> Function() operation, {
  bool recovery = false,
}) async {
  final confirmed = await showGlassDialog<bool>(
    context: context,
    builder: (context) => SPDialog(
      title: AppText(recovery ? '恢复全速任务' : '全速模式风险提示'),
      content: const SizedBox(
        width: 560,
        child: DirectoryScrollView(builder: _warningContent),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const AppText('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const AppText('理解风险并开始'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  String message;
  try {
    await operation();
    final task = catalog.fastTaskState.value;
    message = task == null
        ? '全速任务已完成'
        : task.error == null
        ? '全速任务已暂停'
        : filmCatalogErrorText(task.error!);
  } on FilmCatalogException catch (error) {
    message = filmCatalogErrorText(error.code);
  } on DatabaseException {
    message = filmCatalogErrorText('catalogStorageFailed');
  } on AppException {
    message = filmCatalogErrorText('directoryReadFailed');
  }
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SPNotice(content: AppText(message)));
  }
}

Widget _warningContent(ScrollController controller) => SingleChildScrollView(
  controller: controller,
  child: const AppText(fastTaskWarning),
);

Future<void> showFilmFastTaskOptions(
  BuildContext context,
  FilmCatalogController catalog,
  FilmCatalogRoot root,
) async {
  var scrapeOnly = false;
  var incremental = false;
  String? scope;
  final start = await showGlassDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => SPDialog(
        title: const AppText('全速扫描/刮削'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(root.displayName),
            SwitchListTile(
              title: const AppText('仅刮削现有清单'),
              value: scrapeOnly,
              onChanged: (value) => setState(() {
                scrapeOnly = value;
                incremental = false;
                scope = null;
              }),
            ),
            SwitchListTile(
              title: AppText(scrapeOnly ? '增量刮削' : '增量扫描'),
              value: incremental,
              onChanged: scrapeOnly && root.type != FilmMediaType.tv
                  ? null
                  : (value) => setState(() => incremental = value),
            ),
            if (!scrapeOnly)
              TextButton(
                onPressed: () async {
                  final path = await showGlassDialog<String>(
                    context: context,
                    builder: (_) => FilmDirectoryDialog(
                      source: catalog.sourceFor(root),
                      initialPath: scope ?? root.path,
                      boundaryPath: root.path,
                    ),
                  );
                  if (path != null && context.mounted) {
                    setState(() => scope = path);
                  }
                },
                child: const AppText('指定扫描'),
              ),
            if (scope != null) Text(scope!),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const AppText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const AppText('继续'),
          ),
        ],
      ),
    ),
  );
  if (start != true || !context.mounted) return;
  await runFilmFastTask(
    context,
    catalog,
    () => scrapeOnly
        ? catalog.scrape(
            root,
            incremental: incremental,
            executionMode: FilmTaskExecutionMode.fullSpeed,
          )
        : catalog.scan(
            root,
            incremental: incremental,
            scope: scope == null ? null : FilmScanScope(root.id, scope!),
            executionMode: FilmTaskExecutionMode.fullSpeed,
          ),
  );
}

class FilmFastTaskActions extends StatelessWidget {
  const FilmFastTaskActions({super.key, required this.catalog});
  final FilmCatalogController catalog;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<FilmFastTask?>(
    valueListenable: catalog.fastTaskState,
    builder: (context, task, _) => task == null || task.active
        ? const SizedBox.shrink()
        : Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const AppText('全速任务已暂停'),
              TextButton(
                onPressed: () => runFilmFastTask(
                  context,
                  catalog,
                  catalog.resumeFastTask,
                  recovery: true,
                ),
                child: const AppText('恢复'),
              ),
              TextButton(
                onPressed: catalog.discardFastTask,
                child: const AppText('放弃任务'),
              ),
            ],
          ),
  );
}

/// 挂在 Navigator 内，启动恢复提示可以复用现有弹窗路由。
class FilmFastRecoveryHost extends StatefulWidget {
  const FilmFastRecoveryHost({
    super.key,
    required this.app,
    required this.child,
  });
  final AppState app;
  final Widget child;
  @override
  State<FilmFastRecoveryHost> createState() => _FilmFastRecoveryHostState();
}

class _FilmFastRecoveryHostState extends State<FilmFastRecoveryHost> {
  bool _checked = false;
  @override
  void initState() {
    super.initState();
    widget.app.startupReady.addListener(_ready);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ready());
  }

  Future<void> _ready() async {
    if (_checked || !widget.app.startupReady.value) return;
    _checked = true;
    final catalog = await widget.app.getFilmCatalog();
    if (!mounted ||
        catalog.fastTaskState.value == null ||
        widget.app.fullSpeedExclusive.value) {
      return;
    }
    final action = await showGlassDialog<String>(
      context: context,
      builder: (context) => SPDialog(
        title: const AppText('发现未完成的全速任务'),
        content: const AppText('上次任务进度已保存，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('discard'),
            child: const AppText('放弃任务'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('later'),
            child: const AppText('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('resume'),
            child: const AppText('恢复'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'discard') await catalog.discardFastTask();
    if (action == 'resume' && mounted) {
      await runFilmFastTask(
        context,
        catalog,
        catalog.resumeFastTask,
        recovery: true,
      );
    }
  }

  @override
  void dispose() {
    widget.app.startupReady.removeListener(_ready);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class FilmFastTaskProgress extends StatefulWidget {
  const FilmFastTaskProgress({super.key, required this.catalog});
  final Future<FilmCatalogController> catalog;
  @override
  State<FilmFastTaskProgress> createState() => _FilmFastTaskProgressState();
}

class _FilmFastTaskProgressState extends State<FilmFastTaskProgress> {
  Timer? _timer;
  FilmFastTask? _last;
  DateTime _received = DateTime.now();
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).glass;
    return Stack(
      children: [
        if (tokens.enabled) GlassDialogBackdrop(progress: 1, tokens: tokens),
        ModalBarrier(
          dismissible: false,
          color: tokens.enabled ? Colors.transparent : Colors.black54,
        ),
        FutureBuilder<FilmCatalogController>(
          future: widget.catalog,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return ValueListenableBuilder<FilmFastTask?>(
              valueListenable: snapshot.data!.fastTaskState,
              builder: (context, task, _) {
                if (!identical(_last, task)) {
                  _last = task;
                  _received = DateTime.now();
                }
                final seconds =
                    ((task?.elapsedMs ?? 0) +
                        DateTime.now().difference(_received).inMilliseconds) ~/
                    1000;
                return Center(
                  child: SPDialog(
                    title: const AppText('全速扫描/刮削'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const LinearProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          context.l10n.format(
                            '目录：已完成 {done} / 已发现 {total} · 资源 {files}',
                            {
                              'done': task?.directories ?? 0,
                              'total': task?.discoveredDirectories ?? 0,
                              'files': task?.files ?? 0,
                            },
                          ),
                        ),
                        Text(
                          context.l10n.format(
                            '刮削：已处理 {done} / 已发现 {total} · 已匹配 {matched}',
                            {
                              'done': task?.processed ?? 0,
                              'total': task?.total ?? 0,
                              'matched': task?.matched ?? 0,
                            },
                          ),
                        ),
                        Text(
                          context.l10n.format('耗时：{seconds} 秒', {
                            'seconds': seconds,
                          }),
                        ),
                        if (task?.path.isNotEmpty == true)
                          Text(
                            task!.path,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        const SizedBox(height: 12),
                        const AppText('关闭软件将保存进度并暂停任务'),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => const MethodChannel(
                          'streampath/appearance',
                        ).invokeMethod<void>('close'),
                        autofocus: true,
                        child: const AppText('关闭软件'),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }
}
