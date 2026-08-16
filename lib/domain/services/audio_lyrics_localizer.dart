import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../data/models/audio_media_entry.dart';

typedef AudioLyricsBytesLoader =
    Future<List<int>> Function(
      String url, {
      required int maxBytes,
      required Duration timeout,
    });

class AudioLyricsLocalizationResult {
  const AudioLyricsLocalizationResult({
    required this.entries,
    required this.sessionFiles,
  });

  final List<AudioMediaEntry> entries;
  final List<File> sessionFiles;
}

/// 将远程 LRC 转为当前音频播放会话专用的本地资源。
///
/// 这些文件不保存音频数据，也不会被复用为缓存；MPV 结束后由音频服务删除。
class AudioLyricsLocalizer {
  const AudioLyricsLocalizer({
    this.preparationTimeout = const Duration(seconds: 10),
  });

  static const int maxLyricsBytes = 2 * 1024 * 1024;
  static const int _workerCount = 4;
  final Duration preparationTimeout;

  Future<AudioLyricsLocalizationResult> localize({
    required List<AudioMediaEntry> entries,
    required Directory base,
    required String sessionId,
    AudioLyricsBytesLoader? loader,
  }) async {
    if (!await base.exists()) await base.create(recursive: true);
    final output = entries
        .map(
          (entry) => entry.lyrics != null && _isRemote(entry.lyrics!.url)
              ? entry.copyWith(clearLyrics: true)
              : entry,
        )
        .toList();
    final sessionFiles = <File>[];
    var nextIndex = 0;
    final deadline = DateTime.now().add(preparationTimeout);

    Future<void> worker() async {
      while (nextIndex < entries.length) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) return;
        final index = nextIndex++;
        final lyrics = entries[index].lyrics;
        if (lyrics == null || !_isRemote(lyrics.url)) continue;

        if (loader == null) {
          continue;
        }

        final file = File(
          p.join(
            base.path,
            'streampath-audio-lyrics-${_safeToken(sessionId)}-$index.lrc',
          ),
        );
        try {
          final bytes = await loader(
            lyrics.url,
            maxBytes: maxLyricsBytes,
            timeout: remaining,
          ).timeout(remaining);
          if (bytes.isEmpty || bytes.length > maxLyricsBytes) {
            continue;
          }
          await file.writeAsBytes(bytes, flush: true);
          sessionFiles.add(file);
          output[index] = entries[index].copyWith(
            lyrics: AudioCompanionFile(name: lyrics.name, url: file.path),
          );
        } catch (_) {
          await _deleteIfExists(file);
        }
      }
    }

    final workers = math.min(_workerCount, entries.length);
    await Future.wait(List.generate(workers, (_) => worker()));
    return AudioLyricsLocalizationResult(
      entries: List.unmodifiable(output),
      sessionFiles: List.unmodifiable(sessionFiles),
    );
  }

  Future<void> deleteSessionFiles(Iterable<File> files) async {
    for (final file in files) {
      await _deleteIfExists(file);
    }
  }

  Future<void> deleteSessionArtifacts({
    required Directory base,
    required String sessionId,
  }) async {
    if (!await base.exists()) return;
    final pattern = RegExp(
      '^streampath-audio-lyrics-${RegExp.escape(_safeToken(sessionId))}-'
      r'\d+\.lrc$',
    );
    await for (final entity in base.list(followLinks: false)) {
      if (entity is File && pattern.hasMatch(p.basename(entity.path))) {
        await _deleteIfExists(entity);
      }
    }
  }

  static bool _isRemote(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  static String _safeToken(String sessionId) =>
      sessionId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  static Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 单个会话资源清理失败不得影响播放器和其他模块。
    }
  }
}
