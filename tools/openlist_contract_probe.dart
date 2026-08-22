import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:streampath/domain/services/openlist_api_client.dart';

const _loginHashSuffix = '-https://github.com/alist-org/alist';

Future<void> main() async {
  final environment = Platform.environment;
  final base = Uri.parse(
    _required(environment, 'STREAMPATH_CONTRACT_BASE_URL'),
  );
  final username = _required(environment, 'STREAMPATH_CONTRACT_USERNAME');
  final password = _required(environment, 'STREAMPATH_CONTRACT_PASSWORD');
  final expectedVersion = _required(environment, 'STREAMPATH_CONTRACT_VERSION');
  final expected = <String, bool>{
    'hashLogin': _requiredBool(environment, 'STREAMPATH_CONTRACT_HASH_LOGIN'),
    'indexSearch': _requiredBool(
      environment,
      'STREAMPATH_CONTRACT_INDEX_SEARCH',
    ),
    'indexProgress': _requiredBool(
      environment,
      'STREAMPATH_CONTRACT_INDEX_PROGRESS',
    ),
    'indexUpdate': _requiredBool(
      environment,
      'STREAMPATH_CONTRACT_INDEX_UPDATE',
    ),
    'storageReload': _requiredBool(
      environment,
      'STREAMPATH_CONTRACT_STORAGE_RELOAD',
    ),
  };

  final client = OpenListApiClient();
  final settings = OpenListEnvelope.parse(
    await client.request(
      apiUri(base, '/api/public/settings'),
      method: 'GET',
      timeout: const Duration(seconds: 8),
    ),
  );
  _require(settings.success, '公开设置接口未返回 code 200：${settings.message}');
  final version = settings.dataMap?['version']?.toString().trim() ?? '';
  _require(
    _normalizeVersion(version) == _normalizeVersion(expectedVersion),
    '版本不匹配：期望 $expectedVersion，实际 $version',
  );

  final capabilities = OpenListCapabilities.fromVersion(version);
  _expectSupport('plainLogin', capabilities.plainLogin, true, version: version);
  _expectSupport(
    'hashLogin',
    capabilities.hashLogin,
    expected['hashLogin']!,
    version: version,
  );
  _expectSupport(
    'indexSearch',
    capabilities.indexSearch,
    expected['indexSearch']!,
    version: version,
  );
  _expectSupport(
    'indexProgress',
    capabilities.indexProgress,
    expected['indexProgress']!,
    version: version,
  );
  _expectSupport(
    'indexUpdate',
    capabilities.indexUpdate,
    expected['indexUpdate']!,
    version: version,
  );
  _expectSupport(
    'storageReload',
    capabilities.storageReload,
    expected['storageReload']!,
    version: version,
  );

  final login = await OpenListAuthenticator(client).login(
    base,
    username: username,
    password: password,
    role: '矩阵管理员',
    timeout: const Duration(seconds: 10),
  );
  _require(login.success && login.token != null, login.message);
  final token = login.token!;
  final authorization = <String, String>{
    HttpHeaders.authorizationHeader: token,
  };

  final results = <String, Object?>{'version': version, 'plainLogin': true};
  final hashedPassword = sha256
      .convert(utf8.encode('$password$_loginHashSuffix'))
      .toString();
  final hashLogin = OpenListEnvelope.parse(
    await client.request(
      apiUri(base, '/api/auth/login/hash'),
      method: 'POST',
      body: <String, Object?>{'username': username, 'password': hashedPassword},
      timeout: const Duration(seconds: 8),
    ),
  );
  _expectEndpoint('hashLogin', hashLogin, expected['hashLogin']!);
  if (expected['hashLogin']!) {
    _require(
      hashLogin.success && hashLogin.token != null,
      'login/hash 未成功返回 Token：${hashLogin.message}',
    );
  }
  results['hashLogin'] = _probeSummary(hashLogin);

  final search = OpenListEnvelope.parse(
    await client.request(
      apiUri(base, '/api/fs/search'),
      method: 'POST',
      headers: authorization,
      body: const <String, Object?>{
        'parent': '',
        'keywords': '__streampath_contract_probe__',
        'scope': 0,
        'page': 1,
        'per_page': 1,
      },
      timeout: const Duration(seconds: 8),
    ),
  );
  _expectEndpoint('indexSearch', search, expected['indexSearch']!);
  results['indexSearch'] = _probeSummary(search);

  final progress = OpenListEnvelope.parse(
    await client.request(
      apiUri(base, '/api/admin/index/progress'),
      method: 'GET',
      headers: authorization,
      timeout: const Duration(seconds: 8),
    ),
  );
  _expectEndpoint('indexProgress', progress, expected['indexProgress']!);
  results['indexProgress'] = _probeSummary(progress);

  int? maxDepth;
  if (expected['indexUpdate']!) {
    final maxDepthResponse = OpenListEnvelope.parse(
      await client.request(
        apiUri(base, '/api/admin/setting/get').replace(
          queryParameters: const <String, String>{'key': 'max_index_depth'},
        ),
        method: 'GET',
        headers: authorization,
        timeout: const Duration(seconds: 8),
      ),
    );
    if (maxDepthResponse.success) {
      final rawDepth =
          maxDepthResponse.dataMap?['value'] ?? maxDepthResponse.data;
      final parsedDepth = int.tryParse(rawDepth?.toString() ?? '');
      if (parsedDepth != null && parsedDepth >= -1) maxDepth = parsedDepth;
    }
    results['maxIndexDepth'] = _probeSummary(maxDepthResponse);
  }

  if (expected['indexUpdate']! && maxDepth == null) {
    results['indexUpdate'] = const <String, Object?>{
      'skipped': true,
      'reason': 'max_index_depth 不可用，按应用契约禁止提交 update',
    };
  } else {
    final update = OpenListEnvelope.parse(
      await client.request(
        apiUri(base, '/api/admin/index/update'),
        method: 'POST',
        headers: authorization,
        body: <String, Object?>{
          'paths': const <String>['/'],
          'max_depth': maxDepth ?? -1,
        },
        timeout: const Duration(seconds: 10),
      ),
    );
    _expectEndpoint('indexUpdate', update, expected['indexUpdate']!);
    results['indexUpdate'] = <String, Object?>{
      ..._probeSummary(update),
      'maxDepth': maxDepth,
    };
  }

  final reload = OpenListEnvelope.parse(
    await client.request(
      apiUri(base, '/api/admin/storage/load_all'),
      method: 'POST',
      headers: authorization,
      body: const <String, Object?>{},
      timeout: const Duration(seconds: 10),
    ),
  );
  _expectEndpoint('storageReload', reload, expected['storageReload']!);
  results['storageReload'] = _probeSummary(reload);

  stdout.writeln('STREAMPATH_CONTRACT_RESULT=${jsonEncode(results)}');
}

Map<String, Object?> _probeSummary(OpenListEnvelope envelope) =>
    <String, Object?>{
      'httpStatus': envelope.response.statusCode,
      'code': envelope.code,
      'success': envelope.success,
      'endpointUnavailable': envelope.endpointUnavailable,
      'nonApiFallback': _isNonApiFallback(envelope),
      if (!envelope.success) 'message': _boundedMessage(envelope.message),
      if (!envelope.success) 'messageLength': envelope.message.length,
    };

String _boundedMessage(String value) {
  const limit = 240;
  if (value.length <= limit) return value;
  return '${value.substring(0, limit)}…';
}

void _expectEndpoint(String name, OpenListEnvelope envelope, bool supported) {
  if (supported) {
    final unconfiguredSearch =
        const <String>{
          'indexSearch',
          'indexProgress',
          'indexUpdate',
        }.contains(name) &&
        envelope.response.statusCode == 200 &&
        envelope.code == 404 &&
        envelope.message.trim().toLowerCase() == 'search not available';
    _require(
      unconfiguredSearch ||
          (!envelope.response.failedInTransport &&
              envelope.response.statusCode != null &&
              !envelope.endpointUnavailable),
      '$name 应存在，但响应表明路由不可用：${jsonEncode(_probeSummary(envelope))}',
    );
    return;
  }
  _require(
    envelope.endpointUnavailable || _isNonApiFallback(envelope),
    '$name 应不可用，但响应既不是 404/405，也不是非 API 回退页：${envelope.message}',
  );
}

bool _isNonApiFallback(OpenListEnvelope envelope) {
  final status = envelope.response.statusCode ?? 0;
  return status >= 200 &&
      status < 300 &&
      envelope.payload == null &&
      !envelope.success;
}

void _expectSupport(
  String name,
  OpenListCapabilitySupport actual,
  bool supported, {
  String? version,
}) {
  final expected = supported
      ? OpenListCapabilitySupport.supported
      : OpenListCapabilitySupport.unsupported;
  _require(
    actual == expected,
    '$name 静态能力不匹配：期望 $expected，实际 $actual，'
    '服务端版本=${jsonEncode(version)}',
  );
}

String _required(Map<String, String> environment, String key) {
  final value = environment[key]?.trim() ?? '';
  _require(value.isNotEmpty, '缺少环境变量 $key');
  return value;
}

bool _requiredBool(Map<String, String> environment, String key) {
  final value = _required(environment, key).toLowerCase();
  if (value == 'true') return true;
  if (value == 'false') return false;
  throw FormatException('$key 必须是 true 或 false，实际为 $value');
}

String _normalizeVersion(String value) {
  final match = RegExp(r'[vV]?(\d+\.\d+\.\d+)').firstMatch(value.trim());
  return match?.group(1) ?? value.trim().toLowerCase();
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}
