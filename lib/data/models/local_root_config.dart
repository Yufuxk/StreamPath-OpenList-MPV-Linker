import 'dart:io';

import 'package:path/path.dart' as p;

import 'server_profile.dart';

/// 用户挂载的一个本地目录根。
class LocalRootConfig {
  const LocalRootConfig({
    required this.rootId,
    required this.displayName,
    required this.path,
    this.enabled = true,
  });

  final String rootId;
  final String displayName;
  final String path;
  final bool enabled;

  String get sourceId => 'local:$rootId';

  LocalRootConfig copyWith({
    String? displayName,
    String? path,
    bool? enabled,
  }) => LocalRootConfig(
    rootId: rootId,
    displayName: displayName ?? this.displayName,
    path: path ?? this.path,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'rootId': rootId,
    'displayName': displayName,
    'path': path,
    'enabled': enabled,
  };

  factory LocalRootConfig.fromJson(Map<String, dynamic> json) {
    final rootId = json['rootId'];
    final path = json['path'];
    if (rootId is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(rootId) ||
        path is! String ||
        path.trim().isEmpty ||
        !p.isAbsolute(path.trim())) {
      throw const FormatException('本地根目录配置无效');
    }
    final displayName = (json['displayName'] as String?)?.trim();
    return LocalRootConfig(
      rootId: rootId,
      displayName: displayName?.isNotEmpty == true
          ? displayName!
          : _defaultDisplayName(path),
      path: p.normalize(path.trim()),
      enabled: json['enabled'] != false,
    );
  }

  /// 验证目录可读并保存其最终规范路径。
  static Future<LocalRootConfig> fromDirectory({
    required String path,
    String? displayName,
    String? rootId,
    bool enabled = true,
  }) async {
    final raw = path.trim();
    if (raw.isEmpty || !p.isAbsolute(raw)) {
      throw const FileSystemException('Local root must be an absolute path');
    }
    final directory = Directory(raw);
    if (!await directory.exists()) {
      throw FileSystemException('Local root does not exist', raw);
    }
    final canonical = p.normalize(await directory.resolveSymbolicLinks());
    try {
      await directory.list(followLinks: false).take(1).toList();
    } on FileSystemException {
      rethrow;
    }
    final name = displayName?.trim();
    return LocalRootConfig(
      rootId: rootId ?? ServerProfile.newId(),
      displayName: name?.isNotEmpty == true
          ? name!
          : _defaultDisplayName(canonical),
      path: canonical,
      enabled: enabled,
    );
  }

  static String _defaultDisplayName(String path) {
    final normalized = p.normalize(path);
    final basename = p.basename(normalized).trim();
    return basename.isEmpty ? normalized : basename;
  }
}
