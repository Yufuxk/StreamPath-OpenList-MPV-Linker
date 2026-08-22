import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/utils/file_sort.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/domain/services/media_library_search.dart';

void main() {
  WebDavFile file(String name, {bool directory = false}) => WebDavFile(
    name: name,
    href: '/dav/${Uri.encodeComponent(name)}',
    isDirectory: directory,
  );

  test('全局搜索只收录目录和可播放媒体', () {
    final results = searchVisitedMedia(
      sourceId: 'source-a',
      query: '季',
      snapshots: [
        VisitedDirectorySnapshot(
          path: '动画',
          lastAccessedAt: DateTime.utc(2026, 8, 19),
          entries: [
            file('第一季', directory: true),
            file('第一季.mkv'),
            file('第一季.ass'),
            file('第一季.lrc'),
          ],
        ),
      ],
    );

    expect(results, hasLength(2));
    expect(results.first.item.kind, MediaLibraryKind.directory);
    expect(
      results.map((result) => result.item.kind),
      isNot(contains(MediaLibraryKind.audio)),
    );
  });

  test('当前目录搜索依次应用隐藏后缀、名称匹配和排序并保留返回上级', () {
    final files = [
      const WebDavFile(
        name: '..',
        href: '/dav/',
        isDirectory: true,
        isSelfEntry: true,
      ),
      file('第二集.mkv'),
      file('第一集.mkv'),
      file('第一集.ass'),
      file('说明.txt'),
    ];

    final results = filterCurrentDirectoryFiles(
      files: files,
      hiddenExtensions: const ['.ass'],
      hiddenExtensionsEnabled: true,
      query: '集',
      sortMode: FileSortMode.name,
      sortDirection: FileSortDirection.ascending,
    );

    expect(results.map((file) => file.name), ['..', '第一集.mkv', '第二集.mkv']);
  });

  test('完全匹配、前缀匹配、包含匹配和最近访问依次排序', () {
    final older = DateTime.utc(2026, 8, 18);
    final newer = DateTime.utc(2026, 8, 19);
    final results = searchVisitedMedia(
      sourceId: 'source-a',
      query: 'movie',
      snapshots: [
        VisitedDirectorySnapshot(
          path: 'old',
          lastAccessedAt: older,
          entries: [
            file('Movie', directory: true),
            file('Movie.mkv'),
            file('Movie Night.mkv'),
          ],
        ),
        VisitedDirectorySnapshot(
          path: 'new',
          lastAccessedAt: newer,
          entries: [file('My Movie.mkv'), file('Movie Collection.mkv')],
        ),
      ],
    );

    expect(results.map((result) => result.item.name), [
      'Movie',
      'Movie Collection.mkv',
      'Movie Night.mkv',
      'Movie.mkv',
      'My Movie.mkv',
    ]);
  });

  test('空查询和结果上限受控', () {
    final snapshot = VisitedDirectorySnapshot(
      path: 'music',
      lastAccessedAt: DateTime.utc(2026, 8, 19),
      entries: List.generate(250, (index) => file('track-$index.flac')),
    );

    expect(
      searchVisitedMedia(
        sourceId: 'source-a',
        query: ' ',
        snapshots: [snapshot],
      ),
      isEmpty,
    );
    expect(
      searchVisitedMedia(
        sourceId: 'source-a',
        query: 'track',
        snapshots: [snapshot],
      ),
      hasLength(200),
    );
  });

  test('大规模访问快照使用有界候选且结果与全量排序完全等价', () {
    const snapshotCount = 512;
    const entriesPerSnapshot = 128;
    const limit = 200;
    final baseTime = DateTime.utc(2026, 8, 23, 12);
    final snapshots = List.generate(snapshotCount, (snapshotIndex) {
      return VisitedDirectorySnapshot(
        path: '媒体/$snapshotIndex',
        lastAccessedAt: baseTime.subtract(Duration(minutes: snapshotIndex)),
        entries: List.generate(entriesPerSnapshot, (entryIndex) {
          final name = entryIndex == 0
              ? 'needle'
              : entryIndex.isEven
              ? 'needle-$snapshotIndex-$entryIndex.mkv'
              : '影片-$snapshotIndex-$entryIndex-needle.mkv';
          return file(name, directory: entryIndex == 0);
        }),
      );
    });
    final expected = _referenceFullSort(
      sourceId: 'source-a',
      query: 'needle',
      snapshots: snapshots,
      limit: limit,
    );
    final metrics = MediaLibrarySearchMetrics();
    final stopwatch = Stopwatch()..start();

    final actual = searchVisitedMedia(
      sourceId: 'source-a',
      query: 'needle',
      snapshots: snapshots,
      limit: limit,
      metrics: metrics,
    );
    stopwatch.stop();

    expect(
      actual.map(_resultSignature),
      orderedEquals(expected.map(_resultSignature)),
    );
    expect(metrics.visitedEntryCount, snapshotCount * entriesPerSnapshot);
    expect(metrics.matchedEntryCount, snapshotCount * entriesPerSnapshot);
    expect(metrics.retainedCandidatePeak, lessThanOrEqualTo(limit));
    expect(metrics.materializedItemCount, limit);
    expect(
      metrics.candidateComparisonCount,
      lessThan(snapshotCount * entriesPerSnapshot * 16),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
    // ignore: avoid_print
    print(
      'PERF-03 benchmark: entries=${metrics.visitedEntryCount}, '
      'matches=${metrics.matchedEntryCount}, '
      'candidatePeak=${metrics.retainedCandidatePeak}, '
      'items=${metrics.materializedItemCount}, '
      'comparisons=${metrics.candidateComparisonCount}, '
      'elapsedMs=${stopwatch.elapsedMilliseconds}',
    );
  });

  test('前三个排序键相等时使用稳定键形成有界且确定的全序', () {
    const limit = 17;
    final accessedAt = DateTime.utc(2026, 8, 23, 12);
    final snapshots = List.generate(
      65,
      (index) => VisitedDirectorySnapshot(
        path: '相同排序键/$index',
        lastAccessedAt: accessedAt,
        entries: [file('needle.mkv')],
      ),
    );
    final expected = _referenceFullSort(
      sourceId: 'source-a',
      query: 'needle',
      snapshots: snapshots,
      limit: limit,
    );

    final metrics = MediaLibrarySearchMetrics();
    final actual = searchVisitedMedia(
      sourceId: 'source-a',
      query: 'needle',
      snapshots: snapshots,
      limit: limit,
      metrics: metrics,
    );
    final repeated = searchVisitedMedia(
      sourceId: 'source-a',
      query: 'needle',
      snapshots: snapshots,
      limit: limit,
    );

    expect(
      actual.map(_resultSignature),
      orderedEquals(expected.map(_resultSignature)),
    );
    expect(
      repeated.map(_resultSignature),
      orderedEquals(actual.map(_resultSignature)),
    );
    expect(metrics.retainedCandidatePeak, limit);
    expect(metrics.materializedItemCount, limit);
  });
}

List<MediaLibrarySearchResult> _referenceFullSort({
  required String sourceId,
  required String query,
  required List<VisitedDirectorySnapshot> snapshots,
  required int limit,
}) {
  final normalizedQuery = query.trim().toLowerCase();
  final matches = <({MediaLibrarySearchResult result, int rank})>[];
  final seen = <String>{};
  for (final snapshot in snapshots) {
    for (final file in snapshot.entries) {
      final kind = MediaLibraryKindX.fromFile(file);
      if (kind == null) continue;
      final item = MediaLibraryItem(
        sourceId: sourceId,
        parentPath: snapshot.path,
        name: file.name,
        kind: kind,
      );
      if (!seen.add(item.stableKey)) continue;
      final name = file.name.toLowerCase();
      final fullPath = item.targetPath.toLowerCase();
      if (!name.contains(normalizedQuery) &&
          !fullPath.contains(normalizedQuery)) {
        continue;
      }
      matches.add((
        result: MediaLibrarySearchResult(
          item: item,
          lastAccessedAt: snapshot.lastAccessedAt,
        ),
        rank: name == normalizedQuery
            ? 0
            : name.startsWith(normalizedQuery)
            ? 1
            : 2,
      ));
    }
  }
  matches.sort((left, right) {
    final byRank = left.rank.compareTo(right.rank);
    if (byRank != 0) return byRank;
    final byAccess = right.result.lastAccessedAt.compareTo(
      left.result.lastAccessedAt,
    );
    if (byAccess != 0) return byAccess;
    final byName = left.result.item.name.toLowerCase().compareTo(
      right.result.item.name.toLowerCase(),
    );
    if (byName != 0) return byName;
    return left.result.item.stableKey.compareTo(right.result.item.stableKey);
  });
  return matches.take(limit).map((match) => match.result).toList();
}

String _resultSignature(MediaLibrarySearchResult result) =>
    '${result.item.stableKey}\u0000${result.lastAccessedAt.microsecondsSinceEpoch}';
