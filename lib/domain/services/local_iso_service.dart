import '../../data/models/web_dav_file.dart';
import 'package:path/path.dart' as p;
import '../../data/remote/webdav_client.dart';
import 'local_media_source.dart';
import 'webdav_service.dart';

/// 本地 ISO 复用 Bridge 编排，文件读取始终使用经过本地来源校验的路径。
class LocalIsoService extends WebDAVService {
  LocalIsoService(this.source)
    : super(
        client: WebDavClient(baseUrl: 'http://127.0.0.1/'),
        profileId: source.descriptor.sourceId,
      );

  final LocalMediaSource source;

  @override
  Future<String?> cachedDiscPath(WebDavFile file) =>
      source.resolveDiscDevice(file.relativePath);

  @override
  String persistentUrl(String href) {
    final relative = href.startsWith(baseUrl)
        ? p.joinAll(
            Uri.parse(href).pathSegments.where((part) => part.isNotEmpty),
          )
        : href;
    return Uri.file(
      p.normalize(p.join(source.root.path, relative)),
      windows: true,
    ).toString();
  }
}
