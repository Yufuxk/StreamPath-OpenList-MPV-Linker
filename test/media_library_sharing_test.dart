import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/media_library_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/data/models/app_language.dart';

void main() {
  test('共享模式仅改变展示范围，配置往返保留模式', () {
    const sources = ['local:a', 'local:b', 'server-a', 'server-b'];
    for (final mode in MediaLibrarySharingMode.values) {
      final config = MediaLibraryConfig(sharingMode: mode);
      final reloaded = StreamPathConfig.fromJson(
        StreamPathConfig(mediaLibrary: config).toJson(),
      );
      expect(reloaded.mediaLibrary.sharingMode, mode);
      final local = sources.where(
        (id) => config.includesSource(
          'local:a',
          id,
          mountedProfileIds: {'server-a', 'server-b'},
        ),
      );
      final remote = sources.where(
        (id) => config.includesSource(
          'server-a',
          id,
          mountedProfileIds: {'server-a', 'server-b'},
        ),
      );
      expect(local, switch (mode) {
        MediaLibrarySharingMode.independent => ['local:a'],
        MediaLibrarySharingMode.localShared => ['local:a', 'local:b'],
        MediaLibrarySharingMode.networkShared => ['local:a'],
        MediaLibrarySharingMode.networkAndLocalShared => ['local:a', 'local:b'],
        MediaLibrarySharingMode.allShared => sources,
      });
      expect(remote, switch (mode) {
        MediaLibrarySharingMode.networkShared ||
        MediaLibrarySharingMode.networkAndLocalShared => [
          'server-a',
          'server-b',
        ],
        MediaLibrarySharingMode.allShared => sources,
        _ => ['server-a'],
      });
    }
    expect(
      MediaLibraryConfig.fromJson(null).sharingMode,
      MediaLibrarySharingMode.networkAndLocalShared,
    );
    expect(
      MediaLibraryConfig.fromJson({'sharingMode': 'future'}).sharingMode,
      MediaLibrarySharingMode.networkAndLocalShared,
    );
  });

  test('共享模式文案覆盖其他三种语言', () {
    for (final language in [
      AppLanguage.traditionalChinese,
      AppLanguage.japanese,
      AppLanguage.english,
    ]) {
      for (final label in [
        '数据展示模式',
        '各来源独立',
        '网络存储共享',
        '本地挂载文件夹共享',
        '本地与网络存储共享',
      ]) {
        expect(AppLocalizations(language).text(label), isNot(label));
      }
    }
  });
}
