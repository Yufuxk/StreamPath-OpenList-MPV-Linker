import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/remote/webdav_client.dart' show WebDavDownloadLimit;
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
    this.summary,
  });

  final int completedFiles;
  final int totalFiles;
  final int receivedBytes;
  final int expectedBytes;
  final String fileName;
  final bool fromCache;
  final WebDavFontSummary? summary;
}

enum WebDavFontIssue { network, timeout, limit, format, invalidSize, storage }

class WebDavFontSummary {
  const WebDavFontSummary(
    this.expected,
    this.succeeded,
    this.cacheHits,
    this.issues,
  );

  final int expected;
  final int succeeded;
  final int cacheHits;
  final Map<WebDavFontIssue, int> issues;

  int get skipped =>
      (issues[WebDavFontIssue.limit] ?? 0) +
      (issues[WebDavFontIssue.format] ?? 0);
  int get failed => expected - succeeded - skipped;
  bool get complete => succeeded == expected;
}

class WebDavFontLocalizationResult {
  const WebDavFontLocalizationResult({
    required this.directory,
    required this.files,
    required this.summary,
    this.persistent = false,
  });

  final Directory directory;
  final List<File> files;
  final bool persistent;
  final WebDavFontSummary summary;
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
    Map<String, File> reuse = const {},
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

    final candidates = source.files.take(maxFiles).toList(growable: false);
    final output = List<File?>.filled(candidates.length, null);
    final issues = <WebDavFontIssue, int>{};
    void issue(WebDavFontIssue kind, [int count = 1]) =>
        issues.update(kind, (value) => value + count, ifAbsent: () => count);
    if (source.files.length > candidates.length) {
      issue(WebDavFontIssue.limit, source.files.length - candidates.length);
    }
    var localizedBytes = 0;
    var nextIndex = 0;
    var succeeded = 0;
    var cacheHits = 0;
    final timer = Stopwatch()..start();
    final budget = timeout ?? preparationTimeout;
    final receivedByFile = List<int>.filled(candidates.length, 0);
    final expectedBytes = candidates.fold<int>(
      0,
      (sum, file) => sum + file.size,
    );
    var lastReport = const Duration(milliseconds: -100);

    void report(String fileName, {WebDavFontSummary? summary}) {
      if (onProgress == null) return;
      if (summary == null &&
          timer.elapsed - lastReport < const Duration(milliseconds: 100)) {
        return;
      }
      lastReport = timer.elapsed;
      onProgress(
        WebDavFontLocalizationProgress(
          completedFiles: succeeded,
          totalFiles: source.files.length,
          receivedBytes: receivedByFile.fold<int>(
            0,
            (sum, bytes) => sum + bytes,
          ),
          expectedBytes: expectedBytes,
          fileName: fileName,
          summary: summary,
        ),
      );
    }

    Future<void> worker() async {
      while (nextIndex < candidates.length && timer.elapsed < budget) {
        final index = nextIndex++;
        final font = candidates[index];
        final extension = font.extension;
        if (!AppConstants.fontExtensions.contains(extension)) {
          issue(WebDavFontIssue.format);
          continue;
        }
        if (font.size > maxFontBytes || font.size > maxBytes - localizedBytes) {
          issue(WebDavFontIssue.limit);
          continue;
        }
        final name = '$index$extension';
        final file = File(p.join(directory.path, name));
        final part = File('${file.path}.part');
        final previous = reuse[name];
        WebDavFontIssue? failure;
        for (var attempt = 0; attempt < 2; attempt++) {
          final remaining = budget - timer.elapsed;
          if (remaining <= Duration.zero) {
            failure = WebDavFontIssue.timeout;
            break;
          }
          final timeout =
              attempt == 0 && remaining > const Duration(seconds: 10)
              ? const Duration(seconds: 10)
              : remaining;
          var retry = false;
          try {
            final int length;
            if (previous != null) {
              await previous.copy(part.path);
              length = await part.length();
            } else if (fileLoader != null) {
              length = await fileLoader(
                font.url,
                part,
                maxBytes: maxFontBytes,
                timeout: timeout,
                onProgress: (received) {
                  receivedByFile[index] = received;
                  report(font.name);
                },
              );
            } else {
              final bytes = await loader(
                font.url,
                maxBytes: maxFontBytes,
                timeout: timeout,
              ).timeout(timeout);
              length = bytes.length;
              if (length > 0 && length <= maxFontBytes) {
                await part.writeAsBytes(bytes, flush: true);
              }
            }
            if (length <= 0 || (font.size > 0 && font.size != length)) {
              failure = WebDavFontIssue.invalidSize;
            } else if (length > maxFontBytes ||
                localizedBytes + length > maxBytes) {
              failure = WebDavFontIssue.limit;
            } else {
              localizedBytes += length;
              try {
                output[index] = await part.rename(file.path);
              } on FileSystemException {
                localizedBytes -= length;
                rethrow;
              }
              receivedByFile[index] = length;
              succeeded++;
              if (previous != null) cacheHits++;
              failure = null;
            }
          } on TimeoutException {
            failure = WebDavFontIssue.timeout;
            retry = true;
          } on NetworkException catch (error) {
            final cause = error.cause;
            final status = cause is DioException
                ? cause.response?.statusCode
                : null;
            final timedOut =
                cause is DioException &&
                (cause.type == DioExceptionType.cancel ||
                    cause.type == DioExceptionType.receiveTimeout ||
                    cause.type == DioExceptionType.connectionTimeout ||
                    cause.type == DioExceptionType.sendTimeout);
            failure = timedOut
                ? WebDavFontIssue.timeout
                : WebDavFontIssue.network;
            retry =
                status == null ||
                status == 408 ||
                status == 429 ||
                status >= 500;
          } on IOException catch (error) {
            retry = error is SocketException || error is HttpException;
            failure = retry ? WebDavFontIssue.network : WebDavFontIssue.storage;
          } on ParseException catch (error) {
            failure = error.cause is WebDavDownloadLimit
                ? WebDavFontIssue.limit
                : WebDavFontIssue.invalidSize;
          } on FilmCatalogException {
            failure = WebDavFontIssue.network;
          } finally {
            if (failure != null) {
              receivedByFile[index] = 0;
              await _deleteFile(part);
            }
          }
          if (!retry) break;
        }
        if (failure != null) issue(failure);
        report(font.name);
      }
    }

    try {
      await Future.wait(
        List.generate(
          math.min(_workerCount, candidates.length),
          (_) => worker(),
        ),
      );
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
    if (nextIndex < candidates.length) {
      issue(WebDavFontIssue.timeout, candidates.length - nextIndex);
    }
    final summary = WebDavFontSummary(
      source.files.length,
      succeeded,
      cacheHits,
      Map.unmodifiable(issues),
    );
    report(source.name, summary: summary);
    if (succeeded == 0) {
      await directory.delete();
      return null;
    }
    return WebDavFontLocalizationResult(
      directory: directory,
      files: List.unmodifiable(output.whereType<File>()),
      summary: summary,
    );
  }

  static Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 保留原始下载结果，遗留临时文件随会话目录清理。
    }
  }
}
