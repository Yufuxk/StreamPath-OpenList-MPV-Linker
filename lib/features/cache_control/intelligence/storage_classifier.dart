import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 媒体来源存储类型；只描述链路特性，不包含供应商或账号信息。
enum CacheStorageType {
  local('local', '本地文件'),
  lan('lan', '局域网'),
  cloud('cloud', '云端存储'),
  remote('remote', '远程网络'),
  unknown('unknown', '未知来源');

  const CacheStorageType(this.jsonValue, this.label);

  final String jsonValue;
  final String label;

  static CacheStorageType fromJson(Object? value) {
    return CacheStorageType.values.firstWhere(
      (type) => type.jsonValue == value,
      orElse: () => CacheStorageType.unknown,
    );
  }
}

/// 纯算法存储分类器。不会发起网络请求。
class StorageClassifier {
  const StorageClassifier();

  CacheStorageType classify(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return CacheStorageType.unknown;
    if (_looksLikeWindowsPath(raw)) return CacheStorageType.local;
    Uri uri;
    try {
      uri = Uri.parse(raw);
    } catch (_) {
      return CacheStorageType.unknown;
    }
    if (uri.scheme == 'file') return CacheStorageType.local;
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return uri.scheme.isEmpty
          ? CacheStorageType.local
          : CacheStorageType.unknown;
    }
    final host = uri.host.toLowerCase();
    if (_isLanHost(host)) return CacheStorageType.lan;
    if (_looksLikeCloud(uri, host)) return CacheStorageType.cloud;
    return CacheStorageType.remote;
  }

  /// 只保存来源摘要，不保存 URL、路径、查询参数或认证信息。
  String originHash(String url) {
    try {
      final uri = Uri.parse(url);
      final port = uri.hasPort ? uri.port : _defaultPort(uri.scheme);
      final stable =
          '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:$port';
      return sha256.convert(utf8.encode(stable)).toString();
    } catch (_) {
      return sha256.convert(utf8.encode('unknown')).toString();
    }
  }

  static bool _looksLikeWindowsPath(String value) =>
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(value) || value.startsWith(r'\\');

  static int _defaultPort(String scheme) => scheme == 'https' ? 443 : 80;

  static bool _isLanHost(String host) {
    if (host == 'localhost' || host.endsWith('.local')) return true;
    final ip = InternetAddress.tryParse(host);
    if (ip == null) return false;
    if (ip.type == InternetAddressType.IPv6) {
      return ip.isLoopback ||
          host.toLowerCase().startsWith('fc') ||
          host.toLowerCase().startsWith('fd') ||
          host.toLowerCase().startsWith('fe80');
    }
    final parts = host.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final a = parts[0]!;
    final b = parts[1]!;
    return a == 10 ||
        a == 127 ||
        (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 169 && b == 254);
  }

  static bool _looksLikeCloud(Uri uri, String host) {
    const hostTokens = <String>[
      'amazonaws.com',
      'aliyuncs.com',
      'myqcloud.com',
      'blob.core.windows.net',
      'storage.googleapis.com',
      'cloudfront.net',
      'r2.cloudflarestorage.com',
      'backblazeb2.com',
    ];
    if (hostTokens.any(host.endsWith)) return true;
    final names = uri.queryParameters.keys.map((key) => key.toLowerCase());
    return names.any(
      (name) =>
          name.startsWith('x-amz-') ||
          name.startsWith('x-oss-') ||
          name == 'signature' ||
          name == 'sig' ||
          name == 'expires',
    );
  }
}
