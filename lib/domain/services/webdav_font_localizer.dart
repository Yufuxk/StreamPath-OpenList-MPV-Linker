import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import 'mpv_scripts.dart';
import 'webdav_font_matcher.dart';

typedef WebDavFontBytesLoader =
    Future<List<int>> Function(
      String url, {
      required int maxBytes,
      required Duration timeout,
    });

class WebDavFontLocalizationResult {
  const WebDavFontLocalizationResult({
    required this.directory,
    required this.files,
  });

  final Directory directory;
  final List<File> files;
}

/// 把单个 WebDAV 字体目录转换为本次播放专属的本地字体目录。
class WebDavFontLocalizer {
  const WebDavFontLocalizer({
    this.preparationTimeout = const Duration(seconds: 30),
  });

  static const int maxFontBytes = 64 * 1024 * 1024;
  static const int maxSessionBytes = 512 * 1024 * 1024;
  static const int maxFontFiles = 256;
  static const int _workerCount = 4;

  final Duration preparationTimeout;

  Future<WebDavFontLocalizationResult?> localize({
    required WebDavFontDirectory source,
    required Directory base,
    required String sessionId,
    required WebDavFontBytesLoader loader,
  }) async {
    if (source.files.isEmpty) return null;
    if (!await base.exists()) await base.create(recursive: true);
    final directory = Directory(
      p.join(
        base.path,
        'streampath-fonts-${MpvScripts.safeSessionToken(sessionId)}',
      ),
    );
    await directory.create(recursive: true);

    final output = <File>[];
    var localizedBytes = 0;
    var nextIndex = 0;
    final candidates = source.files.take(maxFontFiles).toList(growable: false);
    final deadline = DateTime.now().add(preparationTimeout);

    Future<void> worker() async {
      while (nextIndex < candidates.length) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) return;
        final index = nextIndex++;
        final font = candidates[index];
        if (font.size > maxFontBytes) continue;
        final extension = font.extension;
        if (!AppConstants.fontExtensions.contains(extension)) continue;
        final file = File(p.join(directory.path, '$index$extension'));
        var reservedBytes = 0;
        try {
          final bytes = await loader(
            font.url,
            maxBytes: maxFontBytes,
            timeout: remaining,
          ).timeout(remaining);
          if (bytes.isEmpty || bytes.length > maxFontBytes) continue;
          if (localizedBytes + bytes.length > maxSessionBytes) continue;
          localizedBytes += bytes.length;
          reservedBytes = bytes.length;
          await file.writeAsBytes(bytes, flush: true);
          output.add(file);
        } catch (_) {
          localizedBytes -= reservedBytes;
          await _deleteFile(file);
        }
      }
    }

    final workers = math.min(_workerCount, candidates.length);
    await Future.wait(List.generate(workers, (_) => worker()));
    if (output.isEmpty) {
      await _deleteDirectory(directory);
      return null;
    }
    return WebDavFontLocalizationResult(
      directory: directory,
      files: List.unmodifiable(output),
    );
  }

  static Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static Future<void> _deleteDirectory(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete();
    } catch (_) {}
  }
}
