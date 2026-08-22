import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../data/models/openlist_index_config.dart';
import '../../data/models/server_profile.dart';
import 'openlist_api_client.dart';
import 'openlist_recovery_service.dart';

/// OpenList/AList 本地索引中的一个文件或目录。
class OpenListIndexEntry {
  const OpenListIndexEntry({
    required this.name,
    required this.parent,
    required this.isDirectory,
    this.size = 0,
  });

  final String name;
  final String parent;
  final bool isDirectory;
  final int size;

  String get path =>
      [...parent.split('/').where((part) => part.isNotEmpty), name].join('/');

  String get parentFolderName {
    final parts = parent.split('/').where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? '/' : parts.last;
  }
}

class OpenListIndexUpdateResult {
  const OpenListIndexUpdateResult({
    required this.accepted,
    required this.message,
    this.alreadyRunning = false,
  });

  final bool accepted;
  final bool alreadyRunning;
  final String message;
}

/// OpenList/AList 后台报告的索引构建状态。
class OpenListIndexProgress {
  const OpenListIndexProgress({
    required this.objectCount,
    required this.isDone,
    this.lastDoneTime,
    this.error = '',
  });

  final int objectCount;
  final bool isDone;
  final DateTime? lastDoneTime;
  final String error;
}

/// 只调用 OpenList/AList 本地索引 API，不递归请求 WebDAV 目录。
class OpenListIndexService {
  OpenListIndexService({
    Dio? dio,
    OpenListRequestSender? requestSender,
    OpenListApiClient? apiClient,
    this.operationTimeout = const Duration(seconds: 30),
  }) : _api =
           apiClient ??
           OpenListApiClient(dio: dio, requestSender: requestSender);

  final OpenListApiClient _api;
  final Duration operationTimeout;
  final Map<String, String> _userTokens = {};
  final Map<String, String> _userBasePaths = {};
  final Map<String, String> _adminTokens = {};
  final Map<String, OpenListCapabilities> _capabilities = {};
  final Set<String> _updatesInFlight = {};

  Future<List<OpenListIndexEntry>> search({
    required ServerProfile profile,
    required String query,
    int limit = 200,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const [];
    final base = _baseUri(profile);
    if (base == null) {
      throw const FormatException('请先配置有效的 OpenList/AList 后台地址');
    }
    final deadline = _api.deadline(operationTimeout);
    final capabilities = await _getCapabilities(profile, deadline);
    if (capabilities.indexSearch == OpenListCapabilitySupport.unsupported) {
      throw FormatException(
        capabilities.unavailableMessage('索引搜索', '/api/fs/search'),
      );
    }

    final tokenSignature = sha256
        .convert(
          utf8.encode(
            '${profile.openListIndex.userToken}\u0000${profile.password}',
          ),
        )
        .toString();
    final sessionKey =
        '${profile.profileId}|${base.origin}${base.path}|'
        '${profile.username.trim()}|$tokenSignature';
    final configuredToken = profile.openListIndex.userToken.trim();
    var token = _userTokens[sessionKey] ?? configuredToken;
    if (token.isEmpty) {
      token = await _login(
        base,
        username: profile.username,
        password: profile.password,
        role: '普通用户',
        deadline: deadline,
      );
    }
    _userTokens[sessionKey] = token;
    var userBasePath = _userBasePaths[sessionKey];
    userBasePath ??= await _loadUserBasePath(base, token, deadline);
    _userBasePaths[sessionKey] = userBasePath;

    var response = await _searchRequest(base, token, keyword, limit, deadline);
    if (_isUnauthorized(response)) {
      _userTokens.remove(sessionKey);
      _userBasePaths.remove(sessionKey);
      if (configuredToken.isNotEmpty) {
        throw const FormatException('普通用户 Token 无效，请填写具有搜索权限的最小权限 Token');
      }
      token = await _login(
        base,
        username: profile.username,
        password: profile.password,
        role: '普通用户',
        deadline: deadline,
      );
      _userTokens[sessionKey] = token;
      userBasePath = await _loadUserBasePath(base, token, deadline);
      _userBasePaths[sessionKey] = userBasePath;
      response = await _searchRequest(base, token, keyword, limit, deadline);
    }
    if (!_isSuccess(response)) {
      throw FormatException('索引搜索失败：${_message(response)}');
    }

    final envelope = _asMap(response.data);
    final data = _asMap(envelope?['data']);
    final rawItems = data?['content'] ?? data?['items'] ?? envelope?['data'];
    if (rawItems is! List) return const [];
    return rawItems
        .whereType<Map>()
        .map(
          (raw) => _parseEntry(
            Map<String, dynamic>.from(raw),
            userBasePath: userBasePath!,
          ),
        )
        .whereType<OpenListIndexEntry>()
        .take(limit.clamp(1, 500))
        .toList(growable: false);
  }

  Future<OpenListIndexProgress> getIndexProgress(ServerProfile profile) async {
    final base = _baseUri(profile);
    if (base == null) {
      throw const FormatException('请先配置有效的 OpenList/AList 后台地址');
    }
    final deadline = _api.deadline(operationTimeout);
    final capabilities = await _getCapabilities(profile, deadline);
    if (capabilities.indexProgress == OpenListCapabilitySupport.unsupported) {
      throw FormatException(
        capabilities.unavailableMessage('索引状态', '/api/admin/index/progress'),
      );
    }
    final adminProgress = await _requestAdminProgress(base, profile, deadline);
    final response = adminProgress.response;
    if (!_isSuccess(response)) {
      final envelope = OpenListEnvelope.parse(response);
      if (envelope.endpointUnavailable) {
        throw const FormatException(
          '索引状态不可用：当前后台缺少 /api/admin/index/progress 端点',
        );
      }
      throw FormatException('读取索引状态失败：${_message(response)}');
    }
    final data = _asMap(_asMap(response.data)?['data']);
    if (data == null || data['is_done'] is! bool) {
      throw const FormatException('OpenList/AList 返回了无法识别的索引状态');
    }
    final rawTime = data['last_done_time'];
    final lastDoneTime = rawTime is DateTime
        ? rawTime
        : DateTime.tryParse(rawTime?.toString() ?? '');
    final objectCount = int.tryParse(data['obj_count']?.toString() ?? '') ?? 0;
    return OpenListIndexProgress(
      objectCount: objectCount < 0 ? 0 : objectCount,
      isDone: data['is_done'] as bool,
      lastDoneTime: lastDoneTime,
      error: data['error']?.toString().trim() ?? '',
    );
  }

  Future<OpenListIndexUpdateResult> updateIndex(ServerProfile profile) async {
    final base = _baseUri(profile);
    if (base == null) {
      return const OpenListIndexUpdateResult(
        accepted: false,
        message: '请先配置有效的 OpenList/AList 后台地址',
      );
    }
    final deadline = _api.deadline(operationTimeout);
    late final OpenListCapabilities capabilities;
    try {
      capabilities = await _getCapabilities(profile, deadline);
    } on FormatException catch (error) {
      return OpenListIndexUpdateResult(
        accepted: false,
        message: error.message.toString(),
      );
    } catch (_) {
      return const OpenListIndexUpdateResult(
        accepted: false,
        message: '索引能力探测异常，请检查后台地址和网络连接',
      );
    }
    if (capabilities.indexProgress == OpenListCapabilitySupport.unsupported) {
      return OpenListIndexUpdateResult(
        accepted: false,
        message: capabilities.unavailableMessage(
          '索引状态',
          '/api/admin/index/progress',
        ),
      );
    }
    if (capabilities.indexUpdate == OpenListCapabilitySupport.unsupported) {
      return OpenListIndexUpdateResult(
        accepted: false,
        message:
            '${capabilities.unavailableMessage('索引增量更新', '/api/admin/index/update')}；不会回退为全量构建',
      );
    }
    final key = '${base.origin}${base.path}';
    if (!_updatesInFlight.add(key)) {
      return const OpenListIndexUpdateResult(
        accepted: false,
        alreadyRunning: true,
        message: '索引更新请求正在处理，请勿重复提交',
      );
    }
    try {
      final adminProgress = await _requestAdminProgress(
        base,
        profile,
        deadline,
      );
      final progress = adminProgress.response;
      final token = adminProgress.token;
      if (!_isSuccess(progress)) {
        return OpenListIndexUpdateResult(
          accepted: false,
          message: '无法读取索引状态：${_message(progress)}',
        );
      }
      final progressData = _asMap(_asMap(progress.data)?['data']);
      if (progressData?['is_done'] == false) {
        return const OpenListIndexUpdateResult(
          accepted: false,
          alreadyRunning: true,
          message: 'OpenList/AList 正在更新索引，本次请求已跳过',
        );
      }

      final maxDepth = await _loadMaxIndexDepth(base, token, deadline);
      final update = await _request(
        _apiUri(base, '/api/admin/index/update'),
        method: 'POST',
        headers: {HttpHeaders.authorizationHeader: token},
        body: <String, Object?>{
          'paths': const <String>['/'],
          'max_depth': maxDepth,
        },
        timeout: deadline.remaining,
      );
      if (!_isSuccess(update)) {
        final envelope = OpenListEnvelope.parse(update);
        if (envelope.endpointUnavailable) {
          return const OpenListIndexUpdateResult(
            accepted: false,
            message: '索引增量更新不可用：当前后台缺少 /api/admin/index/update 端点；不会回退为全量构建',
          );
        }
        return OpenListIndexUpdateResult(
          accepted: false,
          message: '索引更新未启动：${_message(update)}',
        );
      }
      return const OpenListIndexUpdateResult(
        accepted: true,
        message: '索引更新已提交，OpenList/AList 将在后台执行',
      );
    } on FormatException catch (error) {
      return OpenListIndexUpdateResult(
        accepted: false,
        message: error.message.toString(),
      );
    } catch (_) {
      return const OpenListIndexUpdateResult(
        accepted: false,
        message: '索引更新请求异常，请检查后台地址和网络连接',
      );
    } finally {
      _updatesInFlight.remove(key);
    }
  }

  Future<OpenListHttpResponse> _searchRequest(
    Uri base,
    String token,
    String query,
    int limit,
    OpenListRequestDeadline deadline,
  ) => _request(
    _apiUri(base, '/api/fs/search'),
    method: 'POST',
    headers: {HttpHeaders.authorizationHeader: token},
    body: <String, Object?>{
      'parent': '',
      'keywords': query,
      'scope': 0,
      'page': 1,
      'per_page': limit.clamp(1, 500),
    },
    timeout: deadline.remaining,
  );

  Future<String> _loadUserBasePath(
    Uri base,
    String token,
    OpenListRequestDeadline deadline,
  ) async {
    final response = await _request(
      _apiUri(base, '/api/me'),
      method: 'GET',
      headers: {HttpHeaders.authorizationHeader: token},
      timeout: deadline.remaining,
    );
    if (!_isSuccess(response)) {
      throw FormatException('无法读取当前用户根路径：${_message(response)}');
    }
    final data = _asMap(_asMap(response.data)?['data']);
    return _normalizePath(data?['base_path']?.toString() ?? '') ?? '';
  }

  Future<({OpenListHttpResponse response, String token})> _requestAdminProgress(
    Uri base,
    ServerProfile profile,
    OpenListRequestDeadline deadline,
  ) async {
    final recovery = profile.openListRecovery;
    final sessionKey = _adminSessionKey(base, profile);
    var token = _adminTokens[sessionKey];
    token ??= recovery.token.trim();
    if (token.isEmpty) {
      token = await _login(
        base,
        username: recovery.username,
        password: recovery.password,
        role: '管理员',
        deadline: deadline,
      );
    }
    _adminTokens[sessionKey] = token;
    var response = await _request(
      _apiUri(base, '/api/admin/index/progress'),
      method: 'GET',
      headers: {HttpHeaders.authorizationHeader: token},
      timeout: deadline.remaining,
    );
    if (_isUnauthorized(response) &&
        recovery.username.trim().isNotEmpty &&
        recovery.password.isNotEmpty) {
      _adminTokens.remove(sessionKey);
      token = await _login(
        base,
        username: recovery.username,
        password: recovery.password,
        role: '管理员',
        deadline: deadline,
      );
      _adminTokens[sessionKey] = token;
      response = await _request(
        _apiUri(base, '/api/admin/index/progress'),
        method: 'GET',
        headers: {HttpHeaders.authorizationHeader: token},
        timeout: deadline.remaining,
      );
    }
    return (response: response, token: token);
  }

  String _adminSessionKey(Uri base, ServerProfile profile) {
    final recovery = profile.openListRecovery;
    final credentialSignature = sha256
        .convert(utf8.encode('${recovery.token}\u0000${recovery.password}'))
        .toString();
    return '${profile.profileId}|${base.origin}${base.path}|'
        '${recovery.username.trim()}|$credentialSignature';
  }

  Future<int> _loadMaxIndexDepth(
    Uri base,
    String token,
    OpenListRequestDeadline deadline,
  ) async {
    final uri = _apiUri(
      base,
      '/api/admin/setting/get',
    ).replace(queryParameters: const {'key': 'max_index_depth'});
    final response = await _request(
      uri,
      method: 'GET',
      headers: {HttpHeaders.authorizationHeader: token},
      timeout: deadline.remaining,
    );
    if (!_isSuccess(response)) {
      throw FormatException('无法读取最大索引深度：${_message(response)}；已禁止提交索引更新');
    }
    final data = _asMap(_asMap(response.data)?['data']);
    final raw = data?['value'] ?? _asMap(response.data)?['data'];
    final value = int.tryParse(raw?.toString() ?? '');
    if (value == null || value < -1) {
      throw const FormatException('无法解析服务端最大索引深度；已禁止提交索引更新');
    }
    return value;
  }

  Future<String> _login(
    Uri base, {
    required String username,
    required String password,
    required String role,
    required OpenListRequestDeadline deadline,
  }) async {
    final result = await OpenListAuthenticator(_api).login(
      base,
      username: username,
      password: password,
      role: role,
      deadline: deadline,
    );
    if (!result.success) throw FormatException(result.message);
    return result.token!;
  }

  /// 读取公开版本并按功能返回能力矩阵。未知版本保持 unknown，不乐观
  /// 开启无法证明存在的增强端点。
  Future<OpenListCapabilities> getCapabilities(
    ServerProfile profile, {
    Duration timeout = const Duration(seconds: 5),
  }) => _getCapabilities(profile, _api.deadline(timeout));

  Future<OpenListCapabilities> _getCapabilities(
    ServerProfile profile,
    OpenListRequestDeadline deadline,
  ) async {
    final base = _baseUri(profile);
    if (base == null) return OpenListCapabilities.unknown();
    final key = '${base.origin}${base.path}';
    final cached = _capabilities[key];
    if (cached != null) return cached;
    final response = await _request(
      _apiUri(base, '/api/public/settings'),
      method: 'GET',
      timeout: deadline.remaining,
    );
    final envelope = OpenListEnvelope.parse(response);
    // 能力探测的总时间超时已耗尽本次逻辑请求预算，不能再盲发后续管理请求。
    if (response.transportFailure == OpenListTransportFailure.timeout) {
      throw FormatException('读取 OpenList/AList 能力失败：${envelope.message}');
    }
    if (!envelope.success) return OpenListCapabilities.unknown();
    final version =
        envelope.dataMap?['version']?.toString().trim() ??
        envelope.payload?['version']?.toString().trim();
    final capabilities = OpenListCapabilities.fromVersion(version);
    _capabilities[key] = capabilities;
    return capabilities;
  }

  OpenListIndexEntry? _parseEntry(
    Map<String, dynamic> raw, {
    required String userBasePath,
  }) {
    final name = raw['name']?.toString().trim() ?? '';
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\')) {
      return null;
    }
    final indexedParent = _normalizePath(raw['parent']?.toString() ?? '');
    if (indexedParent == null) return null;
    final parent = _relativeToUserBase(indexedParent, userBasePath);
    if (parent == null) return null;
    return OpenListIndexEntry(
      name: name,
      parent: parent,
      isDirectory: raw['is_dir'] == true || raw['isDirectory'] == true,
      size: int.tryParse(raw['size']?.toString() ?? '') ?? 0,
    );
  }

  String? _normalizePath(String raw) {
    final parts = raw
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.any((part) => part == '.' || part == '..')) return null;
    return parts.join('/');
  }

  String? _relativeToUserBase(String path, String basePath) {
    if (basePath.isEmpty) return path;
    if (path == basePath) return '';
    final prefix = '$basePath/';
    return path.startsWith(prefix) ? path.substring(prefix.length) : null;
  }

  Uri? _baseUri(ServerProfile profile) {
    final explicit = OpenListRecoveryService.normalizeBaseUri(
      profile.openListRecovery.baseUrl,
    );
    return explicit ??
        OpenListRecoveryService.normalizeBaseUri(profile.serverUrl);
  }

  Uri _apiUri(Uri base, String endpoint) {
    final prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(path: '$prefix$endpoint', query: null, fragment: null);
  }

  Future<OpenListHttpResponse> _request(
    Uri uri, {
    required String method,
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  }) => _api.request(
    uri,
    method: method,
    headers: headers,
    body: body,
    timeout: timeout ?? const Duration(seconds: 15),
  );

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return null;
  }

  bool _isSuccess(OpenListHttpResponse response) =>
      OpenListEnvelope.parse(response).success;

  bool _isUnauthorized(OpenListHttpResponse response) =>
      OpenListEnvelope.parse(response).unauthorized;

  String _message(OpenListHttpResponse response) {
    return OpenListEnvelope.parse(response).message;
  }
}

typedef OpenListIndexTimerFactory =
    Timer Function(Duration duration, void Function() callback);

/// 单次定时后再调度，确保慢更新不会发生重叠。
class OpenListIndexUpdateScheduler {
  OpenListIndexUpdateScheduler({
    required OpenListIndexService service,
    OpenListIndexTimerFactory? timerFactory,
  }) : _service = service, // ignore: prefer_initializing_formals
       _timerFactory =
           timerFactory ?? ((duration, callback) => Timer(duration, callback));

  final OpenListIndexService _service;
  final OpenListIndexTimerFactory _timerFactory;
  Timer? _timer;
  ServerProfile? _profile;
  bool _disposed = false;

  void configure(ServerProfile? profile) {
    _timer?.cancel();
    _timer = null;
    _profile = profile;
    if (_disposed ||
        profile == null ||
        !profile.openListIndex.autoUpdateEnabled) {
      return;
    }
    final minutes = profile.openListIndex.updateIntervalMinutes.clamp(
      OpenListIndexConfig.minUpdateIntervalMinutes,
      OpenListIndexConfig.maxUpdateIntervalMinutes,
    );
    _timer = _timerFactory(Duration(minutes: minutes), _run);
  }

  Future<void> _run() async {
    final profile = _profile;
    if (_disposed || profile == null) return;
    try {
      await _service.updateIndex(profile);
    } finally {
      if (!_disposed && identical(profile, _profile)) configure(profile);
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
