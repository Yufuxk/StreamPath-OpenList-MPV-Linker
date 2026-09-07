import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/errors/app_exception.dart';
import '../../core/utils/file_sort.dart';
import '../../data/local/stream_path_config_store.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';
import '../../domain/services/media_library_search.dart';
import '../../domain/services/openlist_index_service.dart';
import '../../domain/repositories/media_directory_source.dart';

enum DirectorySearchScope { currentDirectory, openListIndex }

typedef OpenListIndexSearch =
    Future<List<OpenListIndexEntry>> Function(String query);

/// 管理目录浏览、导航、排序与当前目录搜索状态。
///
/// 播放、字幕和媒体资产仍由页面使用完整的 [files] 处理；只有 [visibleFiles]
/// 应用界面过滤、搜索和排序，避免展示逻辑改变播放业务。
class DirectoryBrowserController extends ChangeNotifier {
  DirectoryBrowserController({
    required this.service,
    required this.configStore,
    this.onDirectoryLoaded,
    this.onForcedRefresh,
    this.openListIndexSearch,
  });

  final MediaDirectorySource service;
  final StreamPathConfigStore configStore;
  final Future<void> Function(String path)? onDirectoryLoaded;
  final Future<void> Function()? onForcedRefresh;
  final OpenListIndexSearch? openListIndexSearch;

  final List<String> _crumbs = [];
  List<MediaDirectoryEntry> _files = const [];
  String? _error;
  bool _refreshing = false;
  FileSortMode _sortMode = FileSortMode.name;
  FileSortDirection _sortDirection = FileSortDirection.ascending;
  bool _searchOpen = false;
  String _searchQuery = '';
  DirectorySearchScope _searchScope = DirectorySearchScope.currentDirectory;
  List<OpenListIndexEntry> _indexSearchResults = const [];
  String? _indexSearchError;
  bool _indexSearching = false;
  Timer? _indexSearchDebounce;
  int _indexSearchId = 0;
  int _loadId = 0;
  bool _disposed = false;

  List<MediaDirectoryEntry>? _visibleFilesCache;
  List<MediaDirectoryEntry>? _visibleFilesSource;
  List<String>? _visibleFilesHiddenExtensions;
  bool? _visibleFilesHiddenExtensionsEnabled;
  FileSortMode? _visibleFilesSortMode;
  FileSortDirection? _visibleFilesSortDirection;
  String? _visibleFilesSearchQuery;
  bool _cachedCanSortBySize = false;

  List<String> get crumbs => List.unmodifiable(_crumbs);
  List<MediaDirectoryEntry> get files => _files;
  String? get error => _error;
  bool get refreshing => _refreshing;
  FileSortMode get sortMode => _sortMode;
  FileSortDirection get sortDirection => _sortDirection;
  bool get searchOpen => _searchOpen;
  String get searchQuery => _searchQuery;
  DirectorySearchScope get searchScope => _searchScope;
  List<OpenListIndexEntry> get indexSearchResults => _indexSearchResults;
  String? get indexSearchError => _indexSearchError;
  bool get indexSearching => _indexSearching;
  String get currentPath => _crumbs.join('/');

  List<MediaDirectoryEntry> get visibleFiles {
    _ensureVisibleFilesCache();
    return _visibleFilesCache!;
  }

  bool get canSortBySize {
    _ensureVisibleFilesCache();
    return _cachedCanSortBySize;
  }

  Future<void> initialize() async {
    final previousConfig = configStore.current;
    try {
      await configStore.load();
    } on AppException {
      // 配置损坏时沿用存储提供的默认值，不阻塞目录浏览。
    }
    if (_disposed) return;

    final config = configStore.current;
    final defaultDirectory = config.activeProfile?.defaultDirectory;
    var changed = false;
    if (service.descriptor.kind == MediaSourceKind.webdav &&
        _crumbs.isEmpty &&
        defaultDirectory?.trim().isNotEmpty == true) {
      _crumbs.addAll(_splitPath(defaultDirectory!));
      changed = true;
    }
    if (_sortMode != config.defaultSortMode) {
      _sortMode = config.defaultSortMode;
      changed = true;
    }
    if (_sortDirection != config.defaultSortDirection) {
      _sortDirection = config.defaultSortDirection;
      changed = true;
    }
    final cachedFiles = service.cachedDirectory(currentPath) ?? const [];
    if (!_sameDirectoryEntries(_files, cachedFiles)) {
      _files = cachedFiles;
      changed = true;
    }
    final displayConfigChanged =
        previousConfig.hiddenExtensionsEnabled !=
            config.hiddenExtensionsEnabled ||
        !listEquals(previousConfig.hiddenExtensions, config.hiddenExtensions);
    if (changed || displayConfigChanged) {
      _invalidateVisibleFiles();
      notifyListeners();
    }
    await load();
  }

  Future<void> load({bool force = false}) async {
    if (_disposed) return;
    final loadId = ++_loadId;
    final path = currentPath;
    var initialStateChanged = false;
    if (_error != null) {
      _error = null;
      initialStateChanged = true;
    }
    if (_refreshing != force) {
      _refreshing = force;
      initialStateChanged = true;
    }
    if (initialStateChanged) notifyListeners();
    try {
      final files = await service.fetchDirectory(path, forceRefresh: force);
      if (_disposed || loadId != _loadId || path != currentPath) return;
      if (!_sameDirectoryEntries(_files, files)) {
        _files = files;
        _invalidateVisibleFiles();
        notifyListeners();
      }
      final loadedCallback = onDirectoryLoaded;
      if (loadedCallback != null) {
        unawaited(loadedCallback(path));
      }
      final refreshCallback = onForcedRefresh;
      if (force && refreshCallback != null) {
        unawaited(refreshCallback());
      }
    } on AppException catch (error) {
      if (_disposed || loadId != _loadId || path != currentPath) return;
      if (_error != error.message) {
        _error = error.message;
        notifyListeners();
      }
    } finally {
      if (!_disposed && loadId == _loadId && _refreshing) {
        _refreshing = false;
        notifyListeners();
      }
    }
  }

  void enterDirectory(MediaDirectoryEntry directory) {
    _resetSearch();
    _crumbs.add(directory.name);
    _files = const [];
    _error = null;
    _invalidateVisibleFiles();
    notifyListeners();
  }

  void backTo(int index) {
    _resetSearch();
    _crumbs.removeRange(index + 1, _crumbs.length);
    _files = const [];
    _error = null;
    _invalidateVisibleFiles();
    notifyListeners();
  }

  void navigateToPath(String path) {
    _resetSearch();
    _crumbs
      ..clear()
      ..addAll(_splitPath(path));
    _files = const [];
    _error = null;
    _invalidateVisibleFiles();
    notifyListeners();
  }

  void openSearch() {
    if (_searchOpen) return;
    _searchOpen = true;
    notifyListeners();
  }

  void closeSearch() {
    if (!_searchOpen && _searchQuery.isEmpty) return;
    _resetSearch();
    _invalidateVisibleFiles();
    notifyListeners();
  }

  void updateSearchQuery(String query) {
    if (query == _searchQuery) return;
    _searchQuery = query;
    _invalidateVisibleFiles();
    notifyListeners();
    if (_searchScope == DirectorySearchScope.openListIndex &&
        service.supportsRemoteSearch) {
      _scheduleIndexSearch();
    }
  }

  void updateSearchScope(DirectorySearchScope scope) {
    if (scope == _searchScope) return;
    _searchScope = scope;
    _cancelIndexSearch(
      clearResults: scope != DirectorySearchScope.openListIndex,
    );
    notifyListeners();
    if (scope == DirectorySearchScope.openListIndex) _scheduleIndexSearch();
  }

  void updateSortMode(FileSortMode mode) {
    if (mode == _sortMode) return;
    _sortMode = mode;
    _invalidateVisibleFiles();
    notifyListeners();
  }

  void updateSortDirection(FileSortDirection direction) {
    if (direction == _sortDirection) return;
    _sortDirection = direction;
    _invalidateVisibleFiles();
    notifyListeners();
  }

  void _resetSearch() {
    _cancelIndexSearch(clearResults: true);
    _searchOpen = false;
    _searchQuery = '';
    _searchScope = DirectorySearchScope.currentDirectory;
  }

  void _scheduleIndexSearch() {
    _indexSearchDebounce?.cancel();
    _indexSearchId++;
    final query = _searchQuery.trim();
    if (query.length < 2 || openListIndexSearch == null) {
      if (_cancelIndexSearch(clearResults: true)) notifyListeners();
      return;
    }
    final searchStateChanged = !_indexSearching || _indexSearchError != null;
    _indexSearching = true;
    _indexSearchError = null;
    if (searchStateChanged) notifyListeners();
    _indexSearchDebounce = Timer(
      const Duration(milliseconds: 400),
      () => _runIndexSearch(query),
    );
  }

  Future<void> _runIndexSearch(String query) async {
    final search = openListIndexSearch;
    if (_disposed || search == null) return;
    final searchId = ++_indexSearchId;
    try {
      final results = await search(query);
      if (_disposed ||
          searchId != _indexSearchId ||
          _searchScope != DirectorySearchScope.openListIndex ||
          query != _searchQuery.trim()) {
        return;
      }
      _indexSearchResults = results;
      _indexSearchError = null;
    } catch (error) {
      if (_disposed || searchId != _indexSearchId) return;
      _indexSearchResults = const [];
      _indexSearchError = error is AppException
          ? error.message
          : error is FormatException
          ? error.message.toString()
          : '索引搜索失败，请检查 OpenList/AList 配置';
    } finally {
      if (!_disposed && searchId == _indexSearchId) {
        _indexSearching = false;
        notifyListeners();
      }
    }
  }

  bool _cancelIndexSearch({required bool clearResults}) {
    final changed =
        _indexSearching ||
        _indexSearchError != null ||
        (clearResults && _indexSearchResults.isNotEmpty);
    _indexSearchDebounce?.cancel();
    _indexSearchDebounce = null;
    _indexSearchId++;
    _indexSearching = false;
    _indexSearchError = null;
    if (clearResults) _indexSearchResults = const [];
    return changed;
  }

  void _ensureVisibleFilesCache() {
    final config = configStore.current;
    final hiddenExtensions = config.hiddenExtensions;
    final hiddenExtensionsEnabled = config.hiddenExtensionsEnabled;
    if (identical(_visibleFilesSource, _files) &&
        identical(_visibleFilesHiddenExtensions, hiddenExtensions) &&
        _visibleFilesHiddenExtensionsEnabled == hiddenExtensionsEnabled &&
        _visibleFilesSortMode == _sortMode &&
        _visibleFilesSortDirection == _sortDirection &&
        _visibleFilesSearchQuery == _searchQuery &&
        _visibleFilesCache != null) {
      return;
    }

    final visible = filterCurrentDirectoryEntries(
      files: _files,
      hiddenExtensions: hiddenExtensions,
      hiddenExtensionsEnabled: hiddenExtensionsEnabled,
      query: _searchQuery,
      sortMode: _sortMode,
      sortDirection: _sortDirection,
    );
    _cachedCanSortBySize = canSortMediaEntriesBySize(visible);
    _visibleFilesCache = visible;
    _visibleFilesSource = _files;
    _visibleFilesHiddenExtensions = hiddenExtensions;
    _visibleFilesHiddenExtensionsEnabled = hiddenExtensionsEnabled;
    _visibleFilesSortMode = _sortMode;
    _visibleFilesSortDirection = _sortDirection;
    _visibleFilesSearchQuery = _searchQuery;
  }

  void _invalidateVisibleFiles() {
    _visibleFilesCache = null;
  }

  bool _sameDirectoryEntries(
    List<MediaDirectoryEntry> left,
    List<MediaDirectoryEntry> right,
  ) {
    if (identical(left, right)) return true;
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index];
      final b = right[index];
      if (identical(a, b)) continue;
      if (a.name != b.name ||
          a.entryKey != b.entryKey ||
          a.isDirectory != b.isDirectory ||
          a.isSelfEntry != b.isSelfEntry ||
          a.size != b.size ||
          a.modified != b.modified ||
          a.contentType != b.contentType) {
        return false;
      }
    }
    return true;
  }

  Iterable<String> _splitPath(String path) => path
      .replaceAll('\\', '/')
      .split('/')
      .where((segment) => segment.trim().isNotEmpty);

  @override
  void dispose() {
    _disposed = true;
    _indexSearchDebounce?.cancel();
    _loadId++;
    super.dispose();
  }
}
