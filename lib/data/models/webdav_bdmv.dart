import 'web_dav_file.dart';

/// 已确认的远程光盘目录，保留目录语义，不伪装为 ISO 文件。
class WebDavBdmv extends WebDavFile {
  WebDavBdmv({
    required super.name,
    required super.href,
    required this.rootPath,
    required this.files,
  }) : super(isDirectory: true);

  final String rootPath;
  final List<Map<String, Object>> files;
  String? structureRevision;
}
