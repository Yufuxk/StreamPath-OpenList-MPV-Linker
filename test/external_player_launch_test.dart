import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/subtitle_item.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/mpv_watch_later_sync.dart';

/// launch 集成测试：mpv 字幕注入脚本 + 多集续播（预写 watch_later）。
///
/// 背景（实测确认）：
/// - mpv 的 `--{ ... --}` per-file 作用域对全局选项（--sub-file/--start）
///   不生效，多集字幕改由 sub-add 脚本按 playlist-pos 注入；
/// - 多集续播改由预写首集 watch_later 文件（mpv 原生恢复）；
/// - 单集和多集字幕统一由 sub-add 脚本注入；
/// - 多集每次 `file-loaded` 都按当前 `playlist-pos` 注入对应集字幕；
/// - 自动注入开启时关闭 mpv 自身跨目录字幕搜索，自动选择可独立关闭。
void main() {
  // 用「存在且立即退出」的程序替代真实 mpv，避免测试真启动播放器。
  final exe = Platform.isWindows
      ? r'C:\Windows\System32\where.exe'
      : '/bin/true';

  const sub = SubtitleItem(
    name: '01.srt',
    url: 'http://h/dav/01.srt',
    language: SubtitleLanguage.exact,
  );
  const subZh = SubtitleItem(
    name: '02.chs.srt',
    url: 'http://h/dav/02.chs.srt',
    language: SubtitleLanguage.chinese,
  );

  Future<String> createFakeMpv(Directory dir) async {
    final fakeMpv = File(
      '${dir.path}${Platform.pathSeparator}'
      'mpv-test${Platform.isWindows ? '.exe' : ''}',
    );
    await File(exe).copy(fakeMpv.path);
    return fakeMpv.path;
  }

  Future<(ExternalPlayerService, Directory)> makeService({
    String executable = 'mpv',
    bool subtitleInjectionEnabled = true,
    bool subtitleAutoSelectEnabled = true,
    bool resumeEnabled = true,
  }) async {
    final dir = Directory.systemTemp.createTempSync('sp_launch_');
    var resolvedExecutable = executable;
    if (executable == 'mpv') {
      resolvedExecutable = await createFakeMpv(dir);
    }
    final cfg = StreamPathConfigStore.forPath(
      '${dir.path}${Platform.pathSeparator}cfg.json',
    );
    await cfg.save(
      StreamPathConfig.fromParts(
        PlayerConfig(
          name: 'mpv',
          executable: resolvedExecutable,
          args: const ['--sub-file={subfile}', '{url}', '--start={start}'],
          subtitleInjectionEnabled: subtitleInjectionEnabled,
          subtitleAutoSelectEnabled: subtitleAutoSelectEnabled,
          resumeEnabled: resumeEnabled,
        ),
        const ConnectionConfig(),
      ),
    );
    return (
      ExternalPlayerService(
        configStore: cfg,
        watchLaterDir: Directory('${dir.path}${Platform.pathSeparator}wl'),
      ),
      dir,
    );
  }

  /// 取字幕脚本（single-subtitle / playlist-subtitles）；current.lua
  /// 状态上报脚本不算（单集模式也注入）。
  String? scriptArgOf(List<String> args) {
    for (final a in args) {
      if (a.startsWith('--script=') && !a.endsWith('current.lua')) {
        return a.substring('--script='.length);
      }
    }
    return null;
  }

  /// 取 current.lua 状态上报脚本路径（单集/多集均注入）。
  String? currentScriptOf(List<String> args) {
    for (final a in args) {
      if (a.startsWith('--script=') && a.endsWith('current.lua')) {
        return a.substring('--script='.length);
      }
    }
    return null;
  }

  group('launch 单集：外挂字幕注入与自动选择', () {
    test('自动注入和自动选择开启时以 select 模式加入匹配字幕', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: [MediaEntry(url: 'http://h/dav/01.mp4', subtitle: sub)],
      );
      final scriptPath = scriptArgOf(result.args);
      expect(scriptPath, isNotNull, reason: '应注入 --script= 参数');
      final file = File(scriptPath!);
      expect(file.existsSync(), isTrue, reason: '脚本文件应已写入');
      final content = await file.readAsString();
      expect(content, contains('file-loaded'));
      expect(content, contains('local MODE = "select"'));
      expect(
        content,
        contains('mp.commandv("sub-add", URL, MODE, TITLE, LANG)'),
      );
      expect(content, contains('http://h/dav/01.srt'));
      expect(content, contains('01.srt'));
      expect(result.args, contains('--sub-auto=no'));
      expect(result.args.any((a) => a.startsWith('--sub-file=')), isFalse);
      // mpv 注入 named pipe IPC 参数（实时状态/进度通道；pipe 名唯一）。
      expect(
        result.args.any(
          (a) =>
              a.startsWith('--input-ipc-server=') &&
              a.contains(r'\\.\pipe\mpvsocket_'),
        ),
        isTrue,
        reason: '应注入唯一的 mpv IPC pipe 参数',
      );
    });

    test('两次 launch 生成不同的 IPC pipe 名（防串台）', () async {
      final (service, _) = await makeService();
      String? pipeOf(PlayerLaunchResult r) {
        for (final a in r.args) {
          if (a.startsWith('--input-ipc-server=')) {
            return a.substring('--input-ipc-server='.length);
          }
        }
        return null;
      }

      final first = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
      );
      final second = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
      );
      final p1 = pipeOf(first);
      final p2 = pipeOf(second);
      expect(p1, isNotNull);
      expect(p2, isNotNull);
      expect(p1, isNot(p2), reason: '每次播放 pipe 名应唯一');
      expect(
        p1,
        matches(RegExp(r'^\\\\.\\pipe\\mpvsocket_\d+$')),
        reason: 'pipe 名格式应为 \\\\.\\pipe\\mpvsocket_<单调代际>',
      );
    });

    test('两个显式会话使用完全独立的 IPC、状态文件和播放列表资源', () async {
      final (service, _) = await makeService();
      const entries = [
        MediaEntry(url: 'http://h/dav/01.mp4', title: 'S01E01.mkv'),
        MediaEntry(url: 'http://h/dav/02.mp4', title: 'S01E02.mkv'),
      ];

      final first = await service.launch(
        entries: entries,
        sessionId: 'first-session',
      );
      final second = await service.launch(
        entries: entries,
        sessionId: 'second-session',
      );

      expect(first.sessionId, 'first-session');
      expect(second.sessionId, 'second-session');
      expect(first.ipcPipeName, isNot(second.ipcPipeName));
      expect(first.statusFilePath, isNot(second.statusFilePath));
      expect(first.commandFilePath, isNot(second.commandFilePath));

      String playlistPath(PlayerLaunchResult result) => result.args
          .firstWhere((arg) => arg.startsWith('--playlist='))
          .substring('--playlist='.length);
      expect(playlistPath(first), contains('first-session'));
      expect(playlistPath(second), contains('second-session'));
      expect(playlistPath(first), isNot(playlistPath(second)));

      final firstScripts = first.args
          .where((arg) => arg.startsWith('--script='))
          .toList();
      final secondScripts = second.args
          .where((arg) => arg.startsWith('--script='))
          .toList();
      expect(firstScripts, isNotEmpty);
      expect(secondScripts, isNotEmpty);
      expect(
        firstScripts.every((arg) => arg.contains('first-session')),
        isTrue,
      );
      expect(
        secondScripts.every((arg) => arg.contains('second-session')),
        isTrue,
      );
      expect(firstScripts.toSet().intersection(secondScripts.toSet()), isEmpty);
    });

    test('mpv 无字幕时不注入字幕脚本（但注入状态上报脚本）', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
      );
      expect(scriptArgOf(result.args), isNull, reason: '无字幕脚本');
      final currentPath = currentScriptOf(result.args);
      expect(currentPath, isNotNull, reason: '单集也注入 current.lua（暂停/开始状态同步）');
      // 关键防回归：idle-active 写 -1 播完标记必须受 has_loaded 约束，
      // 防止启动瞬间（未加载文件）误写 -1 导致 UI 误清「继续播放」历史。
      final content = await File(currentPath!).readAsString();
      expect(content, contains('has_loaded'));
      expect(content, contains('if val and has_loaded then'));
    });

    test('自动注入开启但自动选择关闭时以 auto 模式加入并恢复原字幕轨道', () async {
      final (service, _) = await makeService(subtitleAutoSelectEnabled: false);
      final result = await service.launch(
        entries: [MediaEntry(url: 'http://h/dav/01.mp4', subtitle: sub)],
      );
      final scriptPath = scriptArgOf(result.args);
      expect(scriptPath, isNotNull);
      final content = await File(scriptPath!).readAsString();
      expect(content, contains('local MODE = "auto"'));
      expect(
        content,
        contains('mp.commandv("sub-add", URL, MODE, TITLE, LANG)'),
      );
      expect(
        content,
        contains('local previous_sid = mp.get_property("sid", "no")'),
      );
      expect(content, contains('mp.set_property("sid", previous_sid)'));
      expect(content, isNot(contains('local MODE = "select"')));
      expect(result.args, contains('--sub-auto=no'));
      expect(result.args.any((a) => a.startsWith('--sub-file=')), isFalse);
    });

    test('自动注入关闭时不注入字幕参数、脚本或 mpv 自动搜索限制', () async {
      final (service, _) = await makeService(subtitleInjectionEnabled: false);
      final result = await service.launch(
        entries: [MediaEntry(url: 'http://h/dav/01.mp4', subtitle: sub)],
      );
      expect(scriptArgOf(result.args), isNull);
      expect(result.args.any((a) => a.startsWith('--sub-file=')), isFalse);
      expect(result.args, isNot(contains('--sub-auto=no')));
    });

    test('非 mpv 播放器不注入脚本', () async {
      final (service, _) = await makeService(executable: exe);
      final result = await service.launch(
        entries: [MediaEntry(url: 'http://h/dav/01.mp4', subtitle: sub)],
      );
      expect(scriptArgOf(result.args), isNull);
    });

    test('clearStaleFinishedMark：残留 -1 标记清除、正常状态保留', () async {
      final dir = Directory.systemTemp.createTempSync('sp_stale_');

      // 残留「已播完」标记（首行 -1）→ 应删除。
      final stale = File('${dir.path}${Platform.pathSeparator}stale.txt');
      stale.writeAsStringSync('-1\n\n');
      expect(await ExternalPlayerService.clearStaleFinishedMark(stale), isTrue);
      expect(stale.existsSync(), isFalse);

      // 正常状态文件（首行非 -1）→ 保留。
      final normal = File('${dir.path}${Platform.pathSeparator}normal.txt');
      normal.writeAsStringSync('0\nhttp://h/dav/01.mp4\n1');
      expect(
        await ExternalPlayerService.clearStaleFinishedMark(normal),
        isFalse,
      );
      expect(normal.existsSync(), isTrue);

      // 文件不存在 → 无操作。
      final missing = File('${dir.path}${Platform.pathSeparator}missing.txt');
      expect(
        await ExternalPlayerService.clearStaleFinishedMark(missing),
        isFalse,
      );
    });

    test('mpv 单集模板含 subfile 占位符时仍统一使用脚本注入', () async {
      final dir = Directory.systemTemp.createTempSync('sp_launch_');
      final cfg = StreamPathConfigStore.forPath(
        '${dir.path}${Platform.pathSeparator}cfg.json',
      );
      await cfg.save(
        StreamPathConfig.fromParts(
          PlayerConfig(
            name: 'mpv',
            executable: await createFakeMpv(dir),
            args: const ['--sub-file={subfile} --start={start}', '{url}'],
          ),
          const ConnectionConfig(),
        ),
      );
      final service = ExternalPlayerService(
        configStore: cfg,
        watchLaterDir: Directory('${dir.path}${Platform.pathSeparator}wl'),
      );
      final result = await service.launch(
        entries: [MediaEntry(url: 'http://h/dav/01.mp4', subtitle: sub)],
        resumeSeconds: null, // 无进度
      );
      expect(result.args.any((a) => a.startsWith('--sub-file=')), isFalse);
      expect(scriptArgOf(result.args), isNotNull, reason: '外挂字幕应由 Lua 脚本注入');
      // 无进度时禁用恢复并强制从头播放，而非沿用模板的空 --start=。
      expect(result.args, contains('--no-resume-playback'));
      expect(result.args, contains('--start=0'));
    });
  });

  group('launch 标题：mpv 显示当前集文件名而非长 URL', () {
    test('单集注入 --force-media-title 且 URL 原样保留', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: const [
          MediaEntry(
            url: 'http://h/dav/1.EpisodeData/01.mp4',
            title: 'AIR －S01E01－微风~breeze~.mkv',
          ),
        ],
      );
      expect(
        result.args,
        contains('--force-media-title=AIR －S01E01－微风~breeze~.mkv'),
      );
      expect(
        result.args,
        contains('http://h/dav/1.EpisodeData/01.mp4'),
        reason: '直链播放地址必须保持不变',
      );
    });

    test('单集 title 缺省时回退 URL 末段文件名', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
      );
      expect(result.args, contains('--force-media-title=01.mp4'));
    });

    test('非 mpv 播放器不注入标题参数', () async {
      final (service, _) = await makeService(executable: exe);
      final result = await service.launch(
        entries: const [
          MediaEntry(url: 'http://h/dav/01.mp4', title: '01.mp4'),
        ],
      );
      expect(
        result.args.any((a) => a.contains('--force-media-title')),
        isFalse,
      );
    });
  });

  group('launch 多集：m3u 播放列表 + sub-add 脚本 + 预写 watch_later 续播', () {
    test('多集生成 m3u（EXTINF 标题 + EXTVLCOPT + 直链 URL）并注入播放列表脚本', () async {
      final (service, dir) = await makeService();
      final result = await service.launch(
        entries: const [
          MediaEntry(
            url: 'http://h/dav/1.EpisodeData/01.mp4',
            title: 'AIR S01E01.mkv',
            subtitle: sub,
          ),
          MediaEntry(url: 'http://h/dav/1.EpisodeData/02.mp4'),
          MediaEntry(url: 'http://h/dav/1.EpisodeData/03.mp4', subtitle: subZh),
        ],
      );
      // m3u：播放列表标题 + per-file 窗口标题 + 直链 URL（原样保留）。
      final m3u = File(
        '${dir.path}${Platform.pathSeparator}wl'
        '${Platform.pathSeparator}streampath-playlist.m3u',
      );
      expect(m3u.existsSync(), isTrue, reason: '应生成 m3u 播放列表');
      final content = await m3u.readAsString();
      expect(content, startsWith('#EXTM3U'));
      expect(content, contains('#EXTINF:0,AIR S01E01.mkv'));
      expect(content, contains('#EXTVLCOPT:force-media-title=AIR S01E01.mkv'));
      expect(
        content,
        contains('#EXTINF:0,02.mp4'),
        reason: '无 title 的集回退 URL 末段文件名',
      );
      expect(content, contains('http://h/dav/1.EpisodeData/01.mp4'));
      expect(content, contains('http://h/dav/1.EpisodeData/02.mp4'));
      expect(content, contains('http://h/dav/1.EpisodeData/03.mp4'));
      // 参数：--playlist 指向 m3u，不再逐集传 URL。
      expect(result.args, contains('--playlist=${m3u.path}'));
      expect(result.args.any((a) => a.contains('http://h/')), isFalse);
      expect(result.args.any((a) => a.contains('--{')), isFalse);
      // 字幕脚本仍按 playlist-pos 注入（含每集字幕映射）。
      final scriptPath = scriptArgOf(result.args);
      expect(scriptPath, isNotNull);
      final subScript = await File(scriptPath!).readAsString();
      expect(subScript, contains('SUBS[0] = "http://h/dav/01.srt"'));
      expect(subScript, contains('SUBS[2] = "http://h/dav/02.chs.srt"'));
      expect(subScript, contains('local MODE = "select"'));
      expect(subScript, contains('register_event("file-loaded"'));
      expect(subScript, contains('get_property_number("playlist-pos", -1)'));
      expect(subScript, contains('local url = SUBS[pos]'));
      expect(
        subScript,
        contains('mp.commandv("sub-add", url, MODE, TITLES[pos], LANGS[pos])'),
      );
      expect(
        subScript,
        contains('if MODE == "auto" then'),
        reason: '自动选择开启时恢复 sid 的分支存在但不会执行',
      );
      expect(subScript, isNot(contains('SUBS[1]')));
      expect(result.args, contains('--sub-auto=no'));
      expect(result.args.any((a) => a.contains('--sub-file')), isFalse);
      // 无进度时禁用恢复并强制从头；不出现其他 --start 值。
      expect(result.args, contains('--no-resume-playback'));
      expect(result.args.where((a) => a.contains('--start=')).toList(), [
        '--start=0',
      ]);
    });

    test('关闭自动选择后，自动切集仍按 playlist-pos 逐集注入匹配字幕', () async {
      final (service, _) = await makeService(subtitleAutoSelectEnabled: false);
      final result = await service.launch(
        entries: const [
          MediaEntry(url: 'http://h/dav/S01E01.mkv', subtitle: sub),
          MediaEntry(url: 'http://h/dav/S01E02.mkv', subtitle: subZh),
        ],
      );
      final scriptPath = scriptArgOf(result.args);
      expect(scriptPath, isNotNull);
      final content = await File(scriptPath!).readAsString();
      expect(content, contains('local MODE = "auto"'));
      expect(content, contains('SUBS[0] = "http://h/dav/01.srt"'));
      expect(content, contains('SUBS[1] = "http://h/dav/02.chs.srt"'));
      expect(content, contains('register_event("file-loaded"'));
      expect(content, contains('get_property_number("playlist-pos", -1)'));
      expect(content, contains('local url = SUBS[pos]'));
      expect(
        content,
        contains('mp.commandv("sub-add", url, MODE, TITLES[pos], LANGS[pos])'),
      );
      expect(content, contains('mp.set_property("sid", previous_sid)'));
    });

    test('多集注入标题兜底脚本（老版本 mpv 用）', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: const [
          MediaEntry(
            url: 'http://h/dav/1.EpisodeData/AIR S01E01.mkv',
            title: 'AIR S01E01.mkv',
          ),
          MediaEntry(url: 'http://h/dav/1.EpisodeData/02.mp4'),
        ],
      );
      String? titlesScript;
      for (final a in result.args) {
        if (a.startsWith('--script=') && a.endsWith('titles.lua')) {
          titlesScript = a.substring('--script='.length);
          break;
        }
      }
      expect(titlesScript, isNotNull, reason: '应注入标题兜底脚本');
      final content = await File(titlesScript!).readAsString();
      // 自动切集检测上报脚本也应注入（多集模式）。
      String? currentScript;
      for (final a in result.args) {
        if (a.startsWith('--script=') && a.endsWith('current.lua')) {
          currentScript = a.substring('--script='.length);
          break;
        }
      }
      expect(currentScript, isNotNull, reason: '应注入当前播放状态上报脚本');
      final currentContent = await File(currentScript!).readAsString();
      expect(currentContent, contains('playlist-pos'));
      expect(currentContent, contains('file-loaded'));
      expect(currentContent, contains('mpv-current.txt'));
      // 下边栏同步：暂停状态上报 + 命令执行 + 退出/空闲复位。
      expect(currentContent, contains('observe_property("pause"'));
      expect(currentContent, contains('mpv-command.txt'));
      expect(currentContent, contains('add_periodic_timer'));
      expect(currentContent, contains('set_property_bool("pause", true)'));
      expect(currentContent, contains('set_property_bool("pause", false)'));
      expect(currentContent, contains('get_property_number("time-pos"'));
      expect(currentContent, contains('get_property_number("duration"'));
      expect(currentContent, contains('register_event("shutdown"'));
      expect(currentContent, contains('idle-active'));
      // 播放列表播完（最后一个视频结束）时写 pos=-1 标记，
      // 软件据此清除「继续播放」历史。
      expect(currentContent, contains('-1'));
      expect(content, contains('TITLES[0] = "AIR S01E01.mkv"'));
      expect(
        content,
        contains('TITLES[1] = "02.mp4"'),
        reason: '无 title 的集回退 URL 末段文件名',
      );
      expect(content, contains('force-media-title'));
      expect(content, contains('file-loaded'));
    });

    test('多集且首集有进度时预写 watch_later 文件（mpv 原生恢复续播）', () async {
      final (service, dir) = await makeService();
      const url = 'http://h/dav/01.mp4';
      await service.launch(
        entries: const [
          MediaEntry(url: url),
          MediaEntry(url: 'http://h/dav/02.mp4'),
        ],
        resumeSeconds: 90,
      );
      final wlFile = File(
        '${dir.path}${Platform.pathSeparator}wl'
        '${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(url)}',
      );
      expect(wlFile.existsSync(), isTrue, reason: '应预写首集 watch_later');
      expect(await wlFile.readAsString(), contains('start=90'));
    });

    test('playlistStart>0 时续播预写的是播放起点集的 watch_later', () async {
      final (service, dir) = await makeService();
      const firstUrl = 'http://h/dav/01.mp4';
      const startUrl = 'http://h/dav/02.mp4';
      await service.launch(
        entries: const [
          MediaEntry(url: firstUrl),
          MediaEntry(url: startUrl),
          MediaEntry(url: 'http://h/dav/03.mp4'),
        ],
        playlistStart: 1,
        resumeSeconds: 90,
      );
      // 起点集(第 2 集)的 watch_later 被预写,第 1 集不受影响。
      final startWl = File(
        '${dir.path}${Platform.pathSeparator}wl'
        '${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(startUrl)}',
      );
      expect(startWl.existsSync(), isTrue);
      expect(await startWl.readAsString(), contains('start=90'));
      final firstWl = File(
        '${dir.path}${Platform.pathSeparator}wl'
        '${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(firstUrl)}',
      );
      expect(firstWl.existsSync(), isFalse);
    });

    test('无续播进度时清除起点集旧 watch_later（已看完的集从头播）', () async {
      final (service, dir) = await makeService();
      const startUrl = 'http://h/dav/02.mp4';
      final wlDir = Directory('${dir.path}${Platform.pathSeparator}wl');
      wlDir.createSync(recursive: true);
      // 模拟旧 watch_later：位置在片尾（会导致 mpv 秒切下一集）。
      final wlFile = File(
        '${wlDir.path}${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(startUrl)}',
      );
      wlFile.writeAsStringSync('start=3599');

      await service.launch(
        entries: const [
          MediaEntry(url: 'http://h/dav/01.mp4'),
          MediaEntry(url: startUrl),
        ],
        playlistStart: 1,
        resumeSeconds: null, // 已看完 → 从头播
      );
      expect(
        wlFile.existsSync(),
        isFalse,
        reason: '旧 watch_later 应被清除,mpv 从头播放该集',
      );
    });

    test('清除 watch_later 兼容 sanitize 命名（注释行匹配兜底）', () async {
      final (service, dir) = await makeService();
      const startUrl = 'http://h/dav/02.mp4';
      final wlDir = Directory('${dir.path}${Platform.pathSeparator}wl');
      wlDir.createSync(recursive: true);
      // 文件名不是 MD5（模拟 --write-filename-in-watch-later-config），
      // 但首行注释引用了该 URL。
      File(
        '${wlDir.path}${Platform.pathSeparator}wl_02.mp4',
      ).writeAsStringSync('# $startUrl\nstart=3599\n');

      await service.launch(
        entries: const [
          MediaEntry(url: 'http://h/dav/01.mp4'),
          MediaEntry(url: startUrl),
        ],
        playlistStart: 1,
        resumeSeconds: null,
      );
      expect(
        File('${wlDir.path}${Platform.pathSeparator}wl_02.mp4').existsSync(),
        isFalse,
        reason: '扫描兜底应删除注释匹配的旧 watch_later',
      );
    });

    test('多集无进度时不写 watch_later 且强制 --start=0（第一次点击即从头播）', () async {
      final (service, dir) = await makeService();
      const url = 'http://h/dav/01.mp4';
      final result = await service.launch(
        entries: const [
          MediaEntry(url: url),
          MediaEntry(url: 'http://h/dav/02.mp4'),
        ],
        resumeSeconds: null,
      );
      expect(
        result.args,
        contains('--no-resume-playback'),
        reason: '禁用 watch_later 恢复,即使旧记录残留也从头播放',
      );
      expect(result.args, contains('--start=0'));
      final wlFile = File(
        '${dir.path}${Platform.pathSeparator}wl'
        '${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(url)}',
      );
      expect(wlFile.existsSync(), isFalse);
    });

    test('预写 watch_later 保留已有记录并更新 start 行', () async {
      final (service, dir) = await makeService();
      const url = 'http://h/dav/01.mp4';
      final wlDir = Directory('${dir.path}${Platform.pathSeparator}wl');
      wlDir.createSync(recursive: true);
      final wlFile = File(
        '${wlDir.path}${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(url)}',
      );
      wlFile.writeAsStringSync('sid=1\nstart=30\n');

      await service.launch(
        entries: const [
          MediaEntry(url: url),
          MediaEntry(url: 'http://h/dav/02.mp4'),
        ],
        resumeSeconds: 120,
      );
      final content = await wlFile.readAsString();
      expect(content, contains('sid=1'), reason: '其他记录应保留');
      expect(content, contains('start=120'), reason: 'start 行应更新');
      expect(content.contains('start=30'), isFalse);
    });
  });
}
