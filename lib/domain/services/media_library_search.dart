import '../../data/local/directory_cache.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/web_dav_file.dart';
import '../../core/utils/extension_filter.dart';
import '../../core/utils/file_sort.dart';

/// 从完整目录派生当前页面的显示列表，不改变播放、字幕或歌词使用的数据源。
List<WebDavFile> filterCurrentDirectoryFiles({
  required List<WebDavFile> files,
  required List<String> hiddenExtensions,
  required bool hiddenExtensionsEnabled,
  required String query,
  required FileSortMode sortMode,
  required FileSortDirection sortDirection,
}) {
  final hidden = hiddenExtensions.toSet();
  final normalizedQuery = query.trim().toLowerCase();
  final visible = files.where((file) {
    if (file.isSelfEntry) return true;
    if (shouldHideFile(file, hidden, enabled: hiddenExtensionsEnabled)) {
      return false;
    }
    return normalizedQuery.isEmpty ||
        file.name.toLowerCase().contains(normalizedQuery);
  }).toList();
  if (sortMode == FileSortMode.size && !canSortWebDavFilesBySize(visible)) {
    return visible;
  }
  return sortedWebDavFiles(visible, mode: sortMode, direction: sortDirection);
}

/// 访问型全局搜索结果。
class MediaLibrarySearchResult {
  const MediaLibrarySearchResult({
    required this.item,
    required this.lastAccessedAt,
  });

  final MediaLibraryItem item;
  final DateTime lastAccessedAt;
}

/// 搜索过程的可观测计数，用于验证大规模快照的计算与分配上界。
class MediaLibrarySearchMetrics {
  int visitedEntryCount = 0;
  int matchedEntryCount = 0;
  int retainedCandidatePeak = 0;
  int materializedItemCount = 0;
  int candidateComparisonCount = 0;

  void reset() {
    visitedEntryCount = 0;
    matchedEntryCount = 0;
    retainedCandidatePeak = 0;
    materializedItemCount = 0;
    candidateComparisonCount = 0;
  }
}

/// 在已访问的目录快照中搜索目录与可播放媒体。
List<MediaLibrarySearchResult> searchVisitedMedia({
  required String sourceId,
  required String query,
  required List<VisitedDirectorySnapshot> snapshots,
  int limit = 200,
  MediaLibrarySearchMetrics? metrics,
}) {
  metrics?.reset();
  final normalizedQuery = query.trim().toLowerCase();
  if (sourceId.isEmpty || normalizedQuery.isEmpty || limit <= 0) {
    return const [];
  }
  final candidates = <_MediaSearchCandidate>[];
  final seen = <String>{};
  for (final snapshot in snapshots) {
    final parentPath = normalizeLibraryPath(snapshot.path);
    final parentPathLower = parentPath.toLowerCase();
    for (final file in snapshot.entries) {
      metrics?.visitedEntryCount++;
      final kind = MediaLibraryKindX.fromFile(file);
      if (kind == null) continue;
      final name = file.name.toLowerCase();
      var matched =
          name.contains(normalizedQuery) ||
          parentPathLower.contains(normalizedQuery);
      if (!matched) {
        final fullPath = normalizeLibraryPath(
          parentPath.isEmpty ? file.name : '$parentPath/${file.name}',
        ).toLowerCase();
        matched = fullPath.contains(normalizedQuery);
      }
      if (!matched) continue;
      final stableKey = '${kind.name}\u0000$parentPath\u0000${file.name}';
      if (!seen.add(stableKey)) continue;
      final rank = name == normalizedQuery
          ? 0
          : name.startsWith(normalizedQuery)
          ? 1
          : 2;
      metrics?.matchedEntryCount++;
      final candidate = _MediaSearchCandidate(
        parentPath: snapshot.path,
        name: file.name,
        normalizedName: name,
        kind: kind,
        lastAccessedAt: snapshot.lastAccessedAt,
        rank: rank,
        stableKey: stableKey,
      );
      _retainTopCandidate(candidates, candidate, limit, metrics);
    }
  }
  candidates.sort((left, right) => _compareCandidates(left, right, metrics));
  return candidates
      .map((candidate) {
        metrics?.materializedItemCount++;
        return MediaLibrarySearchResult(
          item: MediaLibraryItem(
            sourceId: sourceId,
            parentPath: candidate.parentPath,
            name: candidate.name,
            kind: candidate.kind,
          ),
          lastAccessedAt: candidate.lastAccessedAt,
        );
      })
      .toList(growable: false);
}

class _MediaSearchCandidate {
  const _MediaSearchCandidate({
    required this.parentPath,
    required this.name,
    required this.normalizedName,
    required this.kind,
    required this.lastAccessedAt,
    required this.rank,
    required this.stableKey,
  });

  final String parentPath;
  final String name;
  final String normalizedName;
  final MediaLibraryKind kind;
  final DateTime lastAccessedAt;
  final int rank;
  final String stableKey;
}

void _retainTopCandidate(
  List<_MediaSearchCandidate> heap,
  _MediaSearchCandidate candidate,
  int limit,
  MediaLibrarySearchMetrics? metrics,
) {
  // 堆顶始终是当前最差候选，因此内存中最多保留 limit 项。
  if (heap.length < limit) {
    heap.add(candidate);
    _siftCandidateUp(heap, heap.length - 1, metrics);
    if (metrics != null && heap.length > metrics.retainedCandidatePeak) {
      metrics.retainedCandidatePeak = heap.length;
    }
    return;
  }
  if (_compareCandidates(candidate, heap.first, metrics) >= 0) return;
  heap[0] = candidate;
  _siftCandidateDown(heap, 0, metrics);
}

void _siftCandidateUp(
  List<_MediaSearchCandidate> heap,
  int index,
  MediaLibrarySearchMetrics? metrics,
) {
  var child = index;
  while (child > 0) {
    final parent = (child - 1) >> 1;
    if (_compareCandidates(heap[parent], heap[child], metrics) >= 0) return;
    final value = heap[parent];
    heap[parent] = heap[child];
    heap[child] = value;
    child = parent;
  }
}

void _siftCandidateDown(
  List<_MediaSearchCandidate> heap,
  int index,
  MediaLibrarySearchMetrics? metrics,
) {
  var parent = index;
  while (true) {
    final left = parent * 2 + 1;
    if (left >= heap.length) return;
    final right = left + 1;
    var worseChild = left;
    if (right < heap.length &&
        _compareCandidates(heap[right], heap[left], metrics) > 0) {
      worseChild = right;
    }
    if (_compareCandidates(heap[parent], heap[worseChild], metrics) >= 0) {
      return;
    }
    final value = heap[parent];
    heap[parent] = heap[worseChild];
    heap[worseChild] = value;
    parent = worseChild;
  }
}

int _compareCandidates(
  _MediaSearchCandidate left,
  _MediaSearchCandidate right,
  MediaLibrarySearchMetrics? metrics,
) {
  metrics?.candidateComparisonCount++;
  final byRank = left.rank.compareTo(right.rank);
  if (byRank != 0) return byRank;
  final byAccess = right.lastAccessedAt.compareTo(left.lastAccessedAt);
  if (byAccess != 0) return byAccess;
  final byName = left.normalizedName.compareTo(right.normalizedName);
  if (byName != 0) return byName;
  // 旧比较器在前三项相同时没有定义顺序；稳定键使全排序与 Top-K 使用同一全序。
  return left.stableKey.compareTo(right.stableKey);
}
