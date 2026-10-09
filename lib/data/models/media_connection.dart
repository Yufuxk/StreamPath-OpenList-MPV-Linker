import 'dart:math';
import 'media_source.dart';

class MediaConnection {
  const MediaConnection({
    required this.id,
    required this.kind,
    required this.name,
    required this.url,
    this.username = '',
    this.domain = '',
    this.uid = 65534,
    this.gid = 65534,
    this.nfsVersion = 3,
    this.passive = true,
    this.enabled = true,
    this.readOnly = false,
    this.writeBack = false,
    this.localMetadata = false,
  });
  final String id, name, url, username, domain;
  final MediaSourceKind kind;
  final int uid, gid, nfsVersion;
  final bool passive, enabled, readOnly, writeBack, localMetadata;
  bool get canWrite =>
      !kind.isMediaServer &&
      kind != MediaSourceKind.ftp &&
      !readOnly &&
      writeBack;
  static String newId(MediaSourceKind kind) =>
      '${kind.name}:${DateTime.now().microsecondsSinceEpoch}:${Random.secure().nextInt(1 << 32)}';
  void validate() {
    final uri = Uri.tryParse(url);
    final schemes = kind.isMediaServer
        ? ['http', 'https']
        : kind == MediaSourceKind.ftp
        ? ['ftp', 'ftps']
        : [kind.name];
    if (!kind.isMediaServer && !kind.isNativeStorage ||
        uri == null ||
        uri.host.isEmpty ||
        !schemes.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.any(
          (segment) =>
              segment == '..' ||
              segment == '.' ||
              segment.contains('/') ||
              segment.contains('\\') ||
              segment.contains('\u0000'),
        ) ||
        name.trim().isEmpty ||
        !RegExp(r'^[a-z0-9:._-]+$', caseSensitive: false).hasMatch(id) ||
        uid < 0 ||
        gid < 0 ||
        ![3, 4].contains(nfsVersion)) {
      throw const FormatException('Invalid media connection');
    }
  }

  Map<String, Object> toJson() => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'url': url,
    'username': username,
    'domain': domain,
    'uid': uid,
    'gid': gid,
    'nfsVersion': nfsVersion,
    'passive': passive,
    'enabled': enabled,
    'readOnly': readOnly,
    'writeBack': writeBack,
    'localMetadata': localMetadata,
  };
  factory MediaConnection.fromJson(Map<String, dynamic> json) =>
      MediaConnection(
        id: json['id'] as String,
        kind: MediaSourceKindJson.fromJson(json['kind']),
        name: json['name'] as String,
        url: json['url'] as String,
        username: json['username'] as String? ?? '',
        domain: json['domain'] as String? ?? '',
        uid: json['uid'] as int? ?? 65534,
        gid: json['gid'] as int? ?? 65534,
        nfsVersion: json['nfsVersion'] as int? ?? 3,
        passive: json['passive'] as bool? ?? true,
        enabled: json['enabled'] as bool? ?? true,
        readOnly: json['readOnly'] as bool? ?? false,
        writeBack: json['writeBack'] as bool? ?? false,
        localMetadata: json['localMetadata'] as bool? ?? false,
      );
}
