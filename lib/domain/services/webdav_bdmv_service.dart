import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';
import '../../core/utils/url_utils.dart' as urls;
import '../../data/models/web_dav_file.dart';
import '../../data/models/webdav_bdmv.dart';
import 'webdav_service.dart';

class WebDavBdmvService {
  static bool _strongEtag(String? value) =>
      value != null && RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(value);

  static bool _httpDate(String? value) {
    if (value == null) return false;
    try {
      HttpDate.parse(value);
      return true;
    } on HttpException {
      return false;
    } on FormatException {
      return false;
    }
  }

  static bool isCandidate(String path, Iterable<WebDavFile> entries) =>
      p.posix.basename(path).toLowerCase() == 'bdmv' ||
      entries.any(
        (e) =>
            !e.isSelfEntry &&
            e.isDirectory &&
            Uri.parse(e.href).pathSegments
                    .where((s) => s.isNotEmpty)
                    .lastOrNull
                    ?.toLowerCase() ==
                'bdmv',
      );

  static Future<WebDavBdmv> discover(WebDAVService service, String path) async {
    final root = p.posix.basename(path).toLowerCase() == 'bdmv'
        ? p.posix.dirname(path)
        : path;
    final rootPath = root == '.' ? '' : root.replaceAll(RegExp(r'^/+|/+$'), '');
    final rootUrl = Uri.parse(urls.joinUrl(service.baseUrl, rootPath));
    final segments = rootUrl.pathSegments.where((s) => s.isNotEmpty).toList();
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    var manifestBytes = 0;
    final manifest = <Map<String, Object>>[];
    final seen = <String>{};
    final pending = <(String, int)>[(rootPath, 0)];
    while (pending.isNotEmpty) {
      final batch = pending.take(4).toList();
      pending.removeRange(0, batch.length);
      final listings = await Future.wait(
        batch.map((item) {
          final remaining = deadline.difference(DateTime.now());
          if (remaining <= Duration.zero) {
            throw AppException.network('BDMV 目录读取超时');
          }
          return service
              .fetchDirectory(item.$1, forceRefresh: true)
              .timeout(remaining);
        }),
      );
      for (var i = 0; i < batch.length; i++) {
        final (directory, depth) = batch[i];
        for (final file in listings[i]) {
          if (file.isSelfEntry) continue;
          final url = service.resolveUrl(file.href);
          final uri = Uri.parse(url);
          final child = uri.pathSegments.where((s) => s.isNotEmpty).toList();
          if (!urls.isSameOrigin(service.baseUrl, url) ||
              child.length <= segments.length ||
              List.generate(
                segments.length,
                (i) => child[i] == segments[i],
              ).contains(false)) {
            throw AppException.config('BDMV 目录包含无效路径');
          }
          final relative = child.skip(segments.length).join('/');
          final parent = p.posix.dirname(relative);
          final expected = directory == rootPath
              ? '.'
              : p.posix.relative(
                  directory,
                  from: rootPath.isEmpty ? '.' : rootPath,
                );
          if (parent != expected) throw AppException.config('BDMV 目录包含无效路径');
          if (depth == 0 &&
              file.isDirectory &&
              {'aacs', 'bdsvm'}.contains(relative.toLowerCase())) {
            throw AppException.config('暂不支持 AACS 或 BD+ 加密的 Blu-ray ISO');
          }
          if (depth == 0 &&
              (!file.isDirectory ||
                  !{'bdmv', 'certificate'}.contains(relative.toLowerCase()))) {
            continue;
          }
          if (child.any(
                (part) =>
                    part.isEmpty ||
                    part == '.' ||
                    part == '..' ||
                    part.contains(RegExp(r'[\\:\x00-\x1f<>"|?*]')) ||
                    part.endsWith('.') ||
                    part.endsWith(' ') ||
                    utf8.encode(part).length > 255,
              ) ||
              !seen.add(relative.toLowerCase()) ||
              file.size < 0) {
            throw AppException.config('BDMV 目录包含无效路径');
          }
          final item = <String, Object>{
            'type': 'disc_file',
            'path': relative,
            'url': url,
            'size': file.isDirectory ? 0 : file.size,
            'directory': file.isDirectory,
            if (_strongEtag(file.etag)) 'etag': file.etag!,
            if (_httpDate(file.lastModifiedHeader))
              'lastModified': file.lastModifiedHeader!,
          };
          manifestBytes += utf8.encode(jsonEncode(item)).length;
          if (manifest.length >= 32768 ||
              manifestBytes > 16 * 1024 * 1024 ||
              depth > 16) {
            throw AppException.config('BDMV 目录超出读取限制');
          }
          manifest.add(item);
          if (file.isDirectory) {
            pending.add((
              child
                  .skip(
                    Uri.parse(
                      service.baseUrl,
                    ).pathSegments.where((s) => s.isNotEmpty).length,
                  )
                  .join('/'),
              depth + 1,
            ));
          }
        }
      }
    }
    if (!seen.contains('bdmv/index.bdmv') ||
        !seen.contains('bdmv/playlist') ||
        !seen.contains('bdmv/clipinf') ||
        !seen.contains('bdmv/stream')) {
      throw AppException.config('所选目录不是有效的 Blu-ray BDMV 根目录');
    }
    return WebDavBdmv(
      name: rootPath.isEmpty ? 'BDMV' : p.posix.basename(rootPath),
      href: '${rootUrl.toString().replaceAll(RegExp(r'/+$'), '')}/',
      rootPath: rootPath,
      files: manifest,
    );
  }
}
