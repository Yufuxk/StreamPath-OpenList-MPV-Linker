import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/mpv_session_controller.dart';
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/domain/services/player_process_controller.dart';

Uint8List _wave() {
  const rate = 8000, samples = rate * 10;
  final bytes = Uint8List(44 + samples * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '真实 MPV 可替换工件损坏且 PID 不存在的旧会话',
    () async {
      final temp = await Directory.systemTemp.createTemp('restore_real_mpv_');
      final id = 'restore-real-${DateTime.now().microsecondsSinceEpoch}';
      final cache = await AppPaths.cacheDirectory();
      final artifact = File('${cache.path}/mpv-season-entries-$id.json');
      await artifact.writeAsString('{');
      final config = StreamPathConfigStore.forPath('${temp.path}/config.json');
      await config.save(
        StreamPathConfig(
          playerExecutable: Platform.environment['STREAMPATH_PATH_MPV']!,
          playerArgs: const [
            '--no-config',
            '--vo=null',
            '--ao=null',
            '--pause=yes',
            '{url}',
          ],
          subtitleInjectionEnabled: false,
        ),
      );
      final file = File('${temp.path}/episode.wav');
      await file.writeAsBytes(_wave());
      final player = ExternalPlayerService(
        configStore: config,
        watchLaterDir: Directory('${temp.path}/watch'),
      );
      MpvSessionController? ipc;
      try {
        const oldPid = 2147483640;
        expect(
          await PlayerProcessController().probeUnidentified(oldPid),
          PlayerProcessLiveness.exited,
        );
        await player.restoreSession(sessionId: id, pid: oldPid);
        expect(player.hasRestoreFailure(id), isTrue);
        expect(await player.isPlayerRunning(id), isFalse);
        final launch = await player.launchLocal(
          entries: [MediaEntry(url: file.path)],
          sourceId: 'local:restore-fixture',
          sessionId: id,
        );
        expect(player.hasRestoreFailure(id), isFalse);
        ipc = MpvSessionController(pipeName: launch.ipcPipeName!);
        expect(await ipc.connect(), isTrue);
        expect(await player.isPlayerRunning(id), isTrue);
        expect(
          (await ipc.getProperty('path') as String).replaceAll('\\', '/'),
          file.path.replaceAll('\\', '/'),
        );
        await ipc.dispose();
        ipc = null;
        expect(await player.closeForFilmBoundary(id), isTrue);
        expect(await player.isPlayerRunning(id), isFalse);
      } finally {
        await ipc?.dispose();
        await player.terminateSession(id);
        player.releaseSession(id);
        if (await artifact.exists()) await artifact.delete();
        await temp.delete(recursive: true);
      }
    },
    skip:
        !Platform.isWindows ||
        Platform.environment['STREAMPATH_PATH_MPV'] == null,
  );
  test(
    '真实 MPV 正常退出并完成同步后才允许跨来源重启',
    () async {
      final dir = await Directory.systemTemp.createTemp('film_version_mpv_');
      final config = StreamPathConfigStore.forPath('${dir.path}/config.json');
      await config.save(
        StreamPathConfig(
          playerExecutable: Platform.environment['STREAMPATH_PATH_MPV']!,
          playerArgs: const [
            '--no-config',
            '--vo=null',
            '--ao=null',
            '--pause=yes',
            '{url}',
          ],
          subtitleInjectionEnabled: false,
        ),
      );
      final file = File('${dir.path}/episode.mkv');
      await file.writeAsBytes(_wave());
      final player = ExternalPlayerService(configStore: config);
      PlayerLaunchResult? launch;
      MpvSessionController? ipc;
      try {
        launch = await player.launchLocal(
          entries: [MediaEntry(url: file.path, title: 'Version fixture')],
          sourceId: 'local:version-fixture',
          sessionId: 'version-close',
        );
        ipc = MpvSessionController(pipeName: launch.ipcPipeName!);
        expect(await ipc.connect(), isTrue);
        expect(await player.isPlayerRunning('version-close'), isTrue);
        expect(
          (await ipc.getProperty('path') as String).replaceAll('\\', '/'),
          file.path.replaceAll('\\', '/'),
        );
        await ipc.dispose();
        ipc = null;
        expect(await player.closeForFilmBoundary('version-close'), isTrue);
        expect(await player.isPlayerRunning('version-close'), isFalse);
        final closedPipe = MpvSessionController(pipeName: launch.ipcPipeName!);
        try {
          expect(
            await closedPipe.connect(
              timeout: const Duration(milliseconds: 300),
            ),
            isFalse,
          );
        } finally {
          await closedPipe.dispose();
        }
        expect(await player.closeForFilmBoundary('version-close'), isTrue);
      } finally {
        await ipc?.dispose();
        if (launch != null) await player.terminateSession('version-close');
        await dir.delete(recursive: true);
      }
    },
    skip:
        !Platform.isWindows ||
        Platform.environment['STREAMPATH_PATH_MPV'] == null,
  );
}
