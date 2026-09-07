import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/utils/file_sort.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/media_directory_entry.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/domain/repositories/media_directory_source.dart';
import 'package:streampath/domain/services/openlist_index_service.dart';
import 'package:streampath/presentation/controllers/directory_browser_controller.dart';

void main() {
  late Directory tempDirectory;
  late StreamPathConfigStore configStore;

  setUp(() async {
    tempDirectory = Directory.systemTemp.createTempSync(
      'directory_browser_controller_',
    );
    configStore = StreamPathConfigStore.forPath(
      '${tempDirectory.path}${Platform.pathSeparator}config.json',
    );
    await configStore.save(
      const StreamPathConfig(
        serverUrl: 'https://example.test/dav',
        username: 'user',
        hiddenExtensions: ['.ass'],
      ),
    );
  });

  tearDown(() {
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  test('显示过滤、搜索和排序不改写后台完整目录', () async {
    final allFiles = [
      const WebDavFile(
        name: '..',
        href: '/dav/',
        isDirectory: true,
        isSelfEntry: true,
      ),
      const WebDavFile(
        name: 'B.mkv',
        href: '/dav/B.mkv',
        isDirectory: false,
        size: 20,
      ),
      const WebDavFile(
        name: 'A.ass',
        href: '/dav/A.ass',
        isDirectory: false,
        size: 10,
      ),
      const WebDavFile(
        name: 'C.mkv',
        href: '/dav/C.mkv',
        isDirectory: false,
        size: 30,
      ),
    ];
    final repository = _FakeDirectoryRepository({'': allFiles});
    final controller = DirectoryBrowserController(
      service: repository,
      configStore: configStore,
    );
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(controller.files, same(allFiles));
    expect(controller.visibleFiles.map((file) => file.name), [
      '..',
      'B.mkv',
      'C.mkv',
    ]);
    controller.openSearch();
    controller.updateSearchQuery('c.');
    expect(controller.visibleFiles.map((file) => file.name), ['..', 'C.mkv']);
    expect(controller.files, hasLength(4));

    controller.updateSearchQuery('');
    controller.updateSortMode(FileSortMode.size);
    controller.updateSortDirection(FileSortDirection.descending);
    expect(controller.visibleFiles.map((file) => file.name), [
      '..',
      'C.mkv',
      'B.mkv',
    ]);
  });

  test('较早目录请求晚返回时不能覆盖新导航结果', () async {
    final repository = _DeferredDirectoryRepository();
    final loadedPaths = <String>[];
    final controller = DirectoryBrowserController(
      service: repository,
      configStore: configStore,
      onDirectoryLoaded: (path) async => loadedPaths.add(path),
    );
    addTearDown(controller.dispose);

    final rootLoad = controller.load();
    controller.navigateToPath('新目录');
    final nextLoad = controller.load();
    repository.complete('新目录', [
      const WebDavFile(
        name: 'new.mkv',
        href: '/dav/new.mkv',
        isDirectory: false,
      ),
    ]);
    await nextLoad;
    repository.complete('', [
      const WebDavFile(
        name: 'stale.mkv',
        href: '/dav/stale.mkv',
        isDirectory: false,
      ),
    ]);
    await rootLoad;

    expect(controller.currentPath, '新目录');
    expect(controller.files.single.name, 'new.mkv');
    expect(loadedPaths, ['新目录']);
  });

  test('默认仍搜索当前目录，切换后才延迟查询 OpenList 索引', () async {
    var calls = 0;
    final controller = DirectoryBrowserController(
      service: _FakeDirectoryRepository(const {'': []}),
      configStore: configStore,
      openListIndexSearch: (query) async {
        calls++;
        return const [
          OpenListIndexEntry(name: '目标.mkv', parent: '影视', isDirectory: false),
        ];
      },
    );
    addTearDown(controller.dispose);

    controller.openSearch();
    controller.updateSearchQuery('目标');
    expect(controller.searchScope, DirectorySearchScope.currentDirectory);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(calls, 0);

    controller.updateSearchScope(DirectorySearchScope.openListIndex);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(calls, 1);
    expect(controller.indexSearchResults.single.path, '影视/目标.mkv');
    expect(controller.files, isEmpty);
  });

  test('普通加载和无效索引搜索只在可观察状态变化时通知', () async {
    final files = [
      const WebDavFile(name: 'A.mkv', href: '/dav/A.mkv', isDirectory: false),
    ];
    final controller = DirectoryBrowserController(
      service: _FakeDirectoryRepository({'': files}),
      configStore: configStore,
      openListIndexSearch: (_) async => const [],
    );
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);

    await controller.initialize();
    expect(notifications, 1, reason: '初始化只发布一次缓存目录变化');
    notifications = 0;

    await controller.load();
    expect(notifications, 0, reason: '相同目录的普通加载没有可观察变化');

    await controller.load(force: true);
    expect(notifications, 2, reason: '强制刷新只发布刷新开始和结束');

    controller.openSearch();
    notifications = 0;
    controller.updateSearchScope(DirectorySearchScope.openListIndex);
    expect(notifications, 1, reason: '切换范围只发布范围变化');

    notifications = 0;
    controller.updateSearchQuery('a');
    expect(notifications, 1, reason: '不足两字的查询只发布查询文本变化');
  });
}

class _FakeDirectoryRepository implements MediaDirectorySource {
  _FakeDirectoryRepository(this.directories);

  final Map<String, List<WebDavFile>> directories;

  @override
  MediaSourceDescriptor get descriptor => const MediaSourceDescriptor(
    sourceId: 'webdav:test',
    kind: MediaSourceKind.webdav,
    displayName: 'test',
  );

  @override
  bool get supportsRemoteSearch => true;

  @override
  List<WebDavFile>? cachedDirectory(String path) => directories[path];

  @override
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) async => directories[path] ?? const [];

  @override
  Future<MediaOpenTarget> resolve(MediaDirectoryEntry entry) async =>
      WebDavMediaOpenTarget(entry.entryKey);
}

class _DeferredDirectoryRepository implements MediaDirectorySource {
  final Map<String, Completer<List<WebDavFile>>> _pending = {};

  @override
  MediaSourceDescriptor get descriptor => const MediaSourceDescriptor(
    sourceId: 'webdav:test',
    kind: MediaSourceKind.webdav,
    displayName: 'test',
  );

  @override
  bool get supportsRemoteSearch => true;

  @override
  List<WebDavFile>? cachedDirectory(String path) => null;

  @override
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) => (_pending[path] ??= Completer<List<WebDavFile>>()).future;

  void complete(String path, List<WebDavFile> files) {
    _pending[path]!.complete(files);
  }

  @override
  Future<MediaOpenTarget> resolve(MediaDirectoryEntry entry) async =>
      WebDavMediaOpenTarget(entry.entryKey);
}
