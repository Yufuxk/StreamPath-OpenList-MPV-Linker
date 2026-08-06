import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/utils/file_sort.dart';
import 'package:streampath/data/models/web_dav_file.dart';

void main() {
  WebDavFile file(
    String name, {
    bool directory = false,
    bool self = false,
    int size = 0,
    DateTime? modified,
    String? href,
  }) => WebDavFile(
    name: name,
    href: href ?? '/dav/$name',
    isDirectory: directory,
    isSelfEntry: self,
    size: size,
    modified: modified,
  );

  List<String> sortNames(Iterable<String> names) {
    final result = names.toList()..sort(naturalCompare);
    return result;
  }

  group('自然名称排序', () {
    test('截图中的 S1E1 至 S1E22 按集数排列', () {
      expect(
        sortNames([
          'CLANNAD.4k.S1E1.mkv',
          'CLANNAD.4k.S1E10.mkv',
          'CLANNAD.4k.S1E11.mkv',
          'CLANNAD.4k.S1E2.mkv',
          'CLANNAD.4k.S1E20.mkv',
          'CLANNAD.4k.S1E3.mkv',
        ]),
        [
          'CLANNAD.4k.S1E1.mkv',
          'CLANNAD.4k.S1E2.mkv',
          'CLANNAD.4k.S1E3.mkv',
          'CLANNAD.4k.S1E10.mkv',
          'CLANNAD.4k.S1E11.mkv',
          'CLANNAD.4k.S1E20.mkv',
        ],
      );
    });

    test('常见剧集、分段、纯数字与版本命名均按数字块比较', () {
      expect(sortNames(['EP10', 'EP2']), ['EP2', 'EP10']);
      expect(sortNames(['1x10', '1x2']), ['1x2', '1x10']);
      expect(sortNames(['Part 12', 'Part 3']), ['Part 3', 'Part 12']);
      expect(sortNames(['10.mkv', '2.mkv']), ['2.mkv', '10.mkv']);
      expect(sortNames(['v1.10', 'v1.2']), ['v1.2', 'v1.10']);
      expect(sortNames(['S01.E12', 'S01E2']), ['S01E2', 'S01.E12']);
      expect(sortNames(['Season X', 'Season II']), ['Season II', 'Season X']);
    });

    test('兼容前导零、全角数字、大小写和超长数字', () {
      expect(sortNames(['E001', 'E01', 'E1', 'E2']), [
        'E1',
        'E01',
        'E001',
        'E2',
      ]);
      expect(sortNames(['S１E１０', 's1e2']), ['s1e2', 'S１E１０']);
      expect(sortNames(['A2', 'a10']), ['A2', 'a10']);
      expect(
        sortNames(['n999999999999999999999999', 'n1000000000000000000000000']),
        ['n999999999999999999999999', 'n1000000000000000000000000'],
      );
    });

    test('中文序数按数值比较', () {
      expect(sortNames(['第十集', '第二集', '第九集']), ['第二集', '第九集', '第十集']);
      expect(sortNames(['二十话', '三话', '十一话']), ['三话', '十一话', '二十话']);
    });

    test('名称末尾分隔序号可作为主排序键', () {
      expect(sortNames(['乙片 - 2013.mkv', '甲片 - 2012.mkv']), [
        '甲片 - 2012.mkv',
        '乙片 - 2013.mkv',
      ]);
      expect(sortNames(['Beta_10.mp4', 'Alpha_2.mp4']), [
        'Alpha_2.mp4',
        'Beta_10.mp4',
      ]);
    });

    test('前后都有序号时优先使用名称前方序号', () {
      expect(sortNames(['2. 影片 - 2012.mkv', '1. 影片 - 2013.mkv']), [
        '1. 影片 - 2013.mkv',
        '2. 影片 - 2012.mkv',
      ]);
    });

    test('无分隔的发布数字不作为末尾序号主键', () {
      expect(sortNames(['Beta1080.mkv', 'Alpha2160.mkv']), [
        'Alpha2160.mkv',
        'Beta1080.mkv',
      ]);
    });

    test('显式序号与普通名称混排时保持稳定可传递顺序', () {
      expect(sortNames(['普通名称.mkv', '乙片 - 3.mkv', '甲片 - 2.mkv']), [
        '甲片 - 2.mkv',
        '乙片 - 3.mkv',
        '普通名称.mkv',
      ]);
    });
  });

  group('文件排序规则', () {
    test('返回上级与目录优先级不受排序模式和方向影响', () {
      final entries = [
        file('large.mkv', size: 100),
        file('folder', directory: true),
        file('parent', self: true, directory: true),
      ];
      for (final mode in FileSortMode.values) {
        for (final direction in FileSortDirection.values) {
          expect(
            sortedWebDavFiles(
              entries,
              mode: mode,
              direction: direction,
            ).map((item) => item.name),
            ['parent', 'folder', 'large.mkv'],
          );
        }
      }
    });

    test('时间正序从早到晚，同一分钟忽略秒数并回退自然名称', () {
      final oldE10 = DateTime.utc(2024, 1, 1, 12, 0, 50);
      final oldE2 = DateTime.utc(2024, 1, 1, 12, 0, 10);
      final latest = DateTime.utc(2025);
      final sorted = sortedWebDavFiles([
        file('E10.mkv', modified: oldE10),
        file('unknown.mkv'),
        file('E2.mkv', modified: oldE2),
        file('latest.mkv', modified: latest),
      ], mode: FileSortMode.modified);
      expect(sorted.map((item) => item.name), [
        'E2.mkv',
        'E10.mkv',
        'latest.mkv',
        'unknown.mkv',
      ]);
    });

    test('时间倒序从晚到早，缺失时间仍放最后', () {
      final sameMinuteE2 = DateTime.utc(2024, 1, 1, 12, 0, 10);
      final sameMinuteE10 = DateTime.utc(2024, 1, 1, 12, 0, 50);
      final sorted = sortedWebDavFiles(
        [
          file('E2.mkv', modified: sameMinuteE2),
          file('unknown.mkv'),
          file('E10.mkv', modified: sameMinuteE10),
          file('latest.mkv', modified: DateTime.utc(2025)),
        ],
        mode: FileSortMode.modified,
        direction: FileSortDirection.descending,
      );
      expect(sorted.map((item) => item.name), [
        'latest.mkv',
        'E10.mkv',
        'E2.mkv',
        'unknown.mkv',
      ]);
    });

    test('体积正序从小到大，倒序从大到小', () {
      final entries = [
        file('E10.mkv', size: 10),
        file('large.mkv', size: 20),
        file('E2.mkv', size: 10),
      ];
      final ascending = sortedWebDavFiles(entries, mode: FileSortMode.size);
      expect(ascending.map((item) => item.name), [
        'E2.mkv',
        'E10.mkv',
        'large.mkv',
      ]);

      final sorted = sortedWebDavFiles(
        [
          file('E10.mkv', size: 10),
          file('large.mkv', size: 20),
          file('E2.mkv', size: 10),
        ],
        mode: FileSortMode.size,
        direction: FileSortDirection.descending,
      );
      expect(sorted.map((item) => item.name), [
        'large.mkv',
        'E10.mkv',
        'E2.mkv',
      ]);
    });

    test('体积排序不应用于目录，倒序时目录仍保持自然名称正序', () {
      final sorted = sortedWebDavFiles(
        [file('folder10', directory: true), file('folder2', directory: true)],
        mode: FileSortMode.size,
        direction: FileSortDirection.descending,
      );
      expect(sorted.map((item) => item.name), ['folder2', 'folder10']);
    });

    test('纯目录禁用体积排序，出现普通文件后启用', () {
      expect(
        canSortWebDavFilesBySize([
          file('parent', self: true, directory: true),
          file('folder', directory: true),
        ]),
        isFalse,
      );
      expect(
        canSortWebDavFilesBySize([
          file('folder', directory: true),
          file('video.mkv'),
        ]),
        isTrue,
      );
    });

    test('配置值兼容别名并对未知值回退默认', () {
      expect(fileSortModeFromJson('time'), FileSortMode.modified);
      expect(fileSortModeFromJson('大小'), FileSortMode.size);
      expect(fileSortModeFromJson('unexpected'), FileSortMode.name);
      expect(fileSortModeFromJson(null), FileSortMode.name);
      expect(fileSortDirectionFromJson('desc'), FileSortDirection.descending);
      expect(
        fileSortDirectionFromJson('unexpected'),
        FileSortDirection.ascending,
      );
      expect(fileSortDirectionFromJson(null), FileSortDirection.ascending);
    });
  });
}
