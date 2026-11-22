import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/models/disc_title_selection_policy.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/local_iso_service.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/main_feature_analyzer.dart';
import 'package:streampath/domain/services/webdav_bdmv_service.dart';

MainFeatureCandidate title(
  int playlist,
  int minutes, {
  int clips = 1,
  bool alternate = false,
  bool video = true,
  bool possibleEpisodes = false,
}) => MainFeatureCandidate(
  playlist: playlist,
  duration: Duration(minutes: minutes),
  chapters: 12,
  clips: clips,
  video: video,
  alternate: alternate,
  possibleEpisodes: possibleEpisodes,
);

void main() {
  test(
    'local BDMV discovery builds a validated file manifest for the Bridge',
    () async {
      final root = await Directory.systemTemp.createTemp('disc-policy-');
      addTearDown(() => root.delete(recursive: true));
      const discPath = '光盘 [1]';
      final bdmv = p.join(root.path, discPath, 'BDMV');
      for (final name in ['PLAYLIST', 'CLIPINF', 'STREAM']) {
        await Directory(p.join(bdmv, name)).create(recursive: true);
      }
      await File(p.join(bdmv, 'index.bdmv')).writeAsBytes([1, 2]);
      await File(p.join(bdmv, 'STREAM', '00001.m2ts')).writeAsBytes([3, 4, 5]);
      final source = LocalIsoService(
        LocalMediaSource(
          LocalRootConfig(
            rootId: 'disc-policy',
            displayName: 'Disc policy',
            path: root.path,
          ),
        ),
      );
      final disc = await WebDavBdmvService.discover(source, discPath);
      expect(await source.cachedDiscPath(disc), p.join(root.path, discPath));
      expect(
        disc.files.map((entry) => entry['path']),
        contains('BDMV/STREAM/00001.m2ts'),
      );
      expect(
        source.persistentUrl(disc.href),
        Uri.file(p.join(root.path, discPath), windows: true).toString(),
      );
    },
    skip: !Platform.isWindows,
  );

  test('old and unknown configurations use Full, all policies round-trip', () {
    expect(
      PlayerConfig.fromJson({}).discTitleSelectionPolicy,
      DiscTitleSelectionPolicy.full,
    );
    expect(
      DiscTitleSelectionPolicy.fromJson('invalid'),
      DiscTitleSelectionPolicy.full,
    );
    for (final policy in DiscTitleSelectionPolicy.values) {
      final player = PlayerConfig(
        name: 'MPV',
        executable: 'mpv.exe',
        discTitleSelectionPolicy: policy,
      );
      final defaults = StreamPathConfig.defaults();
      final application = defaults.copyWithGlobalSettings(
        player: player,
        appearance: defaults.appearance,
        mediaLibrary: defaults.mediaLibrary,
      );
      expect(
        PlayerConfig.fromJson(player.toJson()).discTitleSelectionPolicy,
        policy,
      );
      expect(
        StreamPathConfig.fromJson(
          application.toJson(),
        ).toPlayerConfig().discTitleSelectionPolicy,
        policy,
      );
    }
  });

  test('one structured feature may retain its entire multi-clip playlist', () {
    final result = MainFeatureAnalyzer.analyze([
      title(8, 96, clips: 3),
      title(10, 2),
    ], navigationAmbiguous: false);
    expect(result.status, MainFeatureStatus.highConfidence);
    expect(result.playlist, 8);
  });

  test(
    'equal-duration variants, multi-part and episodic discs need a choice',
    () {
      for (final disc in [
        [for (var i = 0; i < 100; i++) title(i, 103, clips: 8)],
        [title(1, 75), title(2, 50)],
        [title(1, 24), title(2, 23), title(3, 25)],
        [title(1, 90), title(2, 8)],
        [title(1, 95, alternate: true)],
        [title(1, 121, clips: 6, possibleEpisodes: true), title(2, 1)],
        [title(1, 75, video: false)],
      ]) {
        final result = MainFeatureAnalyzer.analyze(
          disc,
          navigationAmbiguous: false,
        );
        expect(result.status, MainFeatureStatus.ambiguous);
        expect(result.playlist, isNull);
      }
    },
  );

  test('uncertain navigation requires a still-present confirmed playlist', () {
    final titles = [title(15, 100), title(19, 103)];
    final confirmed = MainFeatureAnalyzer.analyze(
      titles,
      navigationAmbiguous: true,
      confirmedPlaylist: 15,
    );
    final stale = MainFeatureAnalyzer.analyze(
      titles,
      navigationAmbiguous: true,
      confirmedPlaylist: 18,
    );
    expect(confirmed.status, MainFeatureStatus.confirmed);
    expect(confirmed.playlist, 15);
    expect(stale.status, MainFeatureStatus.ambiguous);
    expect(stale.playlist, isNull);
  });

  test(
    'incomplete inventory and invalid candidate metadata cannot auto-select',
    () {
      expect(
        MainFeatureAnalyzer.analyze([], navigationAmbiguous: false).status,
        MainFeatureStatus.unsupported,
      );
      expect(
        MainFeatureCandidate.fromMessage({
          'playlist': 100000,
          'durationMs': 4000000,
          'chapters': 10,
          'clips': 1,
          'video': true,
          'alternate': false,
        }),
        isNull,
      );
    },
  );
}
