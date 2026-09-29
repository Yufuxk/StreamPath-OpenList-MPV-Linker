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

typedef WebDavFontFileLoader =
    Future<int> Function(
      String url,
      File destination, {
      required int maxBytes,
      required Duration timeout,
      void Function(int received)? onProgress,
    });

class WebDavFontLocalizationProgress {
  const WebDavFontLocalizationProgress({
    required this.completedFiles,
    required this.totalFiles,
    required this.receivedBytes,
    required this.expectedBytes,
    required this.fileName,
    this.fromCache = false,
  });

  final int completedFiles;
  final int totalFiles;
  final int receivedBytes;
  final int expectedBytes;
  final String fileName;
  final bool fromCache;
}

class WebDavFontLocalizationResult {
  const WebDavFontLocalizationResult({
    required this.directory,
    required this.files,
    this.persistent = false,
  });

  final Directory directory;
  final List<File> files;
  final bool persistent;
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
    WebDavFontFileLoader? fileLoader,
    int maxFiles = maxFontFiles,
    int maxBytes = maxSessionBytes,
    Duration? timeout,
    void Function(WebDavFontLocalizationProgress progress)? onProgress,
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
    final candidates = source.files.take(maxFiles).toList(growable: false);
    final deadline = DateTime.now().add(timeout ?? preparationTimeout);
    final receivedByFile = List<int>.filled(candidates.length, 0);
    final expectedBytes = candidates.fold<int>(
      0,
      (sum, file) => sum + file.size,
    );
    var completedFiles = 0;
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);

    void report(String fileName, {bool force = false}) {
      if (onProgress == null) return;
      final now = DateTime.now();
      if (!force &&
          now.difference(lastReport) < const Duration(milliseconds: 100)) {
        return;
      }
      lastReport = now;
      onProgress(
        WebDavFontLocalizationProgress(
          completedFiles: completedFiles,
          totalFiles: candidates.length,
          receivedBytes: receivedByFile.fold<int>(
            0,
            (sum, bytes) => sum + bytes,
          ),
          expectedBytes: expectedBytes,
          fileName: fileName,
        ),
      );
    }

    Future<void> worker() async {
      while (nextIndex < candidates.length) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) return;
        final index = nextIndex++;
        final font = candidates[index];
        if (font.size > maxFontBytes) {
          completedFiles++;
          report(font.name, force: true);
          continue;
        }
        final extension = font.extension;
        if (!AppConstants.fontExtensions.contains(extension)) {
          completedFiles++;
          report(font.name, force: true);
          continue;
        }
        final file = File(p.join(directory.path, '$index$extension'));
        var reservedBytes = 0;
        try {
          final int fileBytes;
          if (fileLoader != null) {
            fileBytes = await fileLoader(
              font.url,
              file,
              maxBytes: maxFontBytes,
              timeout: remaining,
              onProgress: (received) {
                receivedByFile[index] = received;
                report(font.name);
              },
            );
          } else {
            final bytes = await loader(
              font.url,
              maxBytes: maxFontBytes,
              timeout: remaining,
            ).timeout(remaining);
            fileBytes = bytes.length;
            receivedByFile[index] = fileBytes;
            if (fileBytes > 0 && fileBytes <= maxFontBytes) {
              await file.writeAsBytes(bytes, flush: true);
            }
          }
          if (fileBytes <= 0 || fileBytes > maxFontBytes) {
            await _deleteFile(file);
            continue;
          }
          if (localizedBytes + fileBytes > maxBytes) {
            await _deleteFile(file);
            continue;
          }
          localizedBytes += fileBytes;
          reservedBytes = fileBytes;
          output.add(file);
        } catch (_) {
          localizedBytes -= reservedBytes;
          await _deleteFile(file);
        } finally {
          completedFiles++;
          report(font.name, force: true);
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
