import 'dart:math';

import '../../core/utils/url_utils.dart';
import 'media_library_item.dart';
import 'openlist_index_config.dart';
import 'openlist_recovery_config.dart';

/// 服务器档案中的敏感信息保存方式。
enum CredentialStorageMode { windowsCredential, portablePlaintext }

extension CredentialStorageModeJson on CredentialStorageMode {
  String get jsonValue => switch (this) {
    CredentialStorageMode.windowsCredential => 'windowsCredential',
    CredentialStorageMode.portablePlaintext => 'portablePlaintext',
  };

  static CredentialStorageMode fromJson(Object? value) => switch (value) {
    'portablePlaintext' => CredentialStorageMode.portablePlaintext,
    _ => CredentialStorageMode.windowsCredential,
  };
}

/// 一组可独立切换的 WebDAV 与 OpenList/AList 配置。
class ServerProfile {
  const ServerProfile({
    required this.profileId,
    required this.name,
    this.serverUrl = '',
    this.username = '',
    this.password = '',
    this.defaultDirectory = '',
    this.openListRecovery = const OpenListRecoveryConfig(),
    this.openListIndex = const OpenListIndexConfig(),
  });

  final String profileId;
  final String name;
  final String serverUrl;
  final String username;
  final String password;
  final String defaultDirectory;
  final OpenListRecoveryConfig openListRecovery;
  final OpenListIndexConfig openListIndex;

  bool get isConnectionComplete =>
      serverUrl.trim().isNotEmpty && username.trim().isNotEmpty;

  ServerProfile copyWith({
    String? profileId,
    String? name,
    String? serverUrl,
    String? username,
    String? password,
    String? defaultDirectory,
    OpenListRecoveryConfig? openListRecovery,
    OpenListIndexConfig? openListIndex,
  }) => ServerProfile(
    profileId: profileId ?? this.profileId,
    name: name ?? this.name,
    serverUrl: serverUrl ?? this.serverUrl,
    username: username ?? this.username,
    password: password ?? this.password,
    defaultDirectory: defaultDirectory ?? this.defaultDirectory,
    openListRecovery: openListRecovery ?? this.openListRecovery,
    openListIndex: openListIndex ?? this.openListIndex,
  );

  Map<String, dynamic> toJson({bool includeSecrets = true}) => {
    'profileId': profileId,
    'name': name,
    'serverUrl': serverUrl,
    'username': username,
    if (includeSecrets) 'password': password,
    'defaultDirectory': defaultDirectory,
    'openListRecovery': openListRecovery.toJson(includeSecrets: includeSecrets),
    'openListIndex': openListIndex.toJson(includeSecrets: includeSecrets),
  };

  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    final profileId = json['profileId'];
    if (profileId is! String || profileId.trim().isEmpty) {
      throw const FormatException('服务器档案缺少 profileId');
    }
    final normalizedId = profileId.trim();
    if (!RegExp(
      r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
    ).hasMatch(normalizedId)) {
      throw const FormatException('服务器档案 profileId 格式无效');
    }
    return ServerProfile(
      profileId: normalizedId,
      name: ((json['name'] as String?) ?? '未命名服务器').trim(),
      serverUrl: stripUserInfo((json['serverUrl'] as String?) ?? ''),
      username: (json['username'] as String?) ?? '',
      password: (json['password'] as String?) ?? '',
      defaultDirectory: _normalizeDirectory(
        (json['defaultDirectory'] as String?) ?? '',
      ),
      openListRecovery: OpenListRecoveryConfig.fromJson(
        json['openListRecovery'] is Map
            ? Map<String, dynamic>.from(json['openListRecovery'] as Map)
            : null,
      ),
      openListIndex: OpenListIndexConfig.fromJson(
        json['openListIndex'] is Map
            ? Map<String, dynamic>.from(json['openListIndex'] as Map)
            : null,
      ),
    );
  }

  /// 旧单账号迁移沿用原媒体来源标识，避免收藏与访问索引失联。
  static String legacyId({
    required String serverUrl,
    required String username,
  }) => mediaSourceId(baseUrl: serverUrl, username: username);

  /// 新建档案使用与地址、账号无关的随机 ID，编辑档案后仍保持稳定。
  static String newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-'
        '${hex(8, 10)}-${hex(10, 16)}';
  }

  static String _normalizeDirectory(String value) {
    final segments = value
        .trim()
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.any((segment) => segment == '.' || segment == '..')) {
      throw const FormatException('默认目录不能包含 . 或 .. 路径段');
    }
    return segments.join('/');
  }
}
