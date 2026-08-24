import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../../core/errors/app_exception.dart';

/// 一个服务器档案需要从配置文件中移出的敏感字段。
class ProfileSecrets {
  const ProfileSecrets({
    this.webDavPassword = '',
    this.openListPassword = '',
    this.openListToken = '',
    this.openListUserToken = '',
  });

  final String webDavPassword;
  final String openListPassword;
  final String openListToken;
  final String openListUserToken;

  bool get isEmpty =>
      webDavPassword.isEmpty &&
      openListPassword.isEmpty &&
      openListToken.isEmpty &&
      openListUserToken.isEmpty;

  Map<String, dynamic> toJson() => {
    'webDavPassword': webDavPassword,
    'openListPassword': openListPassword,
    'openListToken': openListToken,
    'openListUserToken': openListUserToken,
  };

  factory ProfileSecrets.fromJson(Map<String, dynamic> json) => ProfileSecrets(
    webDavPassword: (json['webDavPassword'] as String?) ?? '',
    openListPassword: (json['openListPassword'] as String?) ?? '',
    openListToken: (json['openListToken'] as String?) ?? '',
    openListUserToken: (json['openListUserToken'] as String?) ?? '',
  );
}

abstract interface class ProfileCredentialStore {
  bool get isSupported;

  Future<ProfileSecrets?> read(String profileId);

  Future<void> write(String profileId, ProfileSecrets secrets);

  Future<void> delete(String profileId);
}

/// Windows 凭据管理器中的通用凭据实现。
class WindowsProfileCredentialStore implements ProfileCredentialStore {
  const WindowsProfileCredentialStore();

  static const _targetPrefix = 'StreamPath/server-profile/';
  static const _credentialNotFound = 1168;

  /// 初始化当前线程的 Win32 错误状态，确保后续读取真实错误码。
  static void _primeLastError() => GetLastError();

  @override
  bool get isSupported => Platform.isWindows;

  @override
  Future<ProfileSecrets?> read(String profileId) async {
    if (!isSupported) return null;
    final target = '$_targetPrefix$profileId'.toNativeUtf16();
    final result = calloc<Pointer<CREDENTIAL>>();
    try {
      _primeLastError();
      if (CredRead(target, CRED_TYPE_GENERIC, 0, result) != TRUE) {
        final error = GetLastError();
        if (error == _credentialNotFound) return null;
        throw WindowsException(HRESULT_FROM_WIN32(error));
      }
      final credential = result.value.ref;
      final bytes = credential.CredentialBlob.asTypedList(
        credential.CredentialBlobSize,
      );
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map) throw const FormatException('凭据内容不是 JSON 对象');
      return ProfileSecrets.fromJson(Map<String, dynamic>.from(json));
    } on FormatException catch (error) {
      throw AppException.config('Windows 凭据内容损坏', error);
    } catch (error) {
      if (error is AppException) rethrow;
      throw AppException.storage('读取 Windows 凭据失败', error);
    } finally {
      if (result.value.address != 0) CredFree(result.value);
      calloc.free(result);
      calloc.free(target);
    }
  }

  @override
  Future<void> write(String profileId, ProfileSecrets secrets) async {
    if (!isSupported) {
      throw AppException.storage('当前平台不支持 Windows 凭据管理器');
    }
    final target = '$_targetPrefix$profileId'.toNativeUtf16();
    final userName = 'StreamPath'.toNativeUtf16();
    final bytes = utf8.encode(jsonEncode(secrets.toJson()));
    final blob = calloc<Uint8>(bytes.length);
    blob.asTypedList(bytes.length).setAll(0, bytes);
    final credential = calloc<CREDENTIAL>()
      ..ref.Type = CRED_TYPE_GENERIC
      ..ref.TargetName = target
      ..ref.Persist = CRED_PERSIST_LOCAL_MACHINE
      ..ref.UserName = userName
      ..ref.CredentialBlob = blob
      ..ref.CredentialBlobSize = bytes.length;
    try {
      _primeLastError();
      if (CredWrite(credential, 0) != TRUE) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }
    } catch (error) {
      throw AppException.storage('写入 Windows 凭据失败', error);
    } finally {
      calloc.free(blob);
      calloc.free(credential);
      calloc.free(userName);
      calloc.free(target);
    }
  }

  @override
  Future<void> delete(String profileId) async {
    if (!isSupported) return;
    final target = '$_targetPrefix$profileId'.toNativeUtf16();
    try {
      _primeLastError();
      if (CredDelete(target, CRED_TYPE_GENERIC, 0) != TRUE) {
        final error = GetLastError();
        if (error != _credentialNotFound) {
          throw WindowsException(HRESULT_FROM_WIN32(error));
        }
      }
    } catch (error) {
      throw AppException.storage('删除 Windows 凭据失败', error);
    } finally {
      calloc.free(target);
    }
  }
}

/// 仅供测试注入，避免自动化测试修改真实 Windows 凭据。
class MemoryProfileCredentialStore implements ProfileCredentialStore {
  MemoryProfileCredentialStore([Map<String, ProfileSecrets>? values])
    : _values = values ?? {};

  final Map<String, ProfileSecrets> _values;

  @override
  bool get isSupported => true;

  @override
  Future<ProfileSecrets?> read(String profileId) async => _values[profileId];

  @override
  Future<void> write(String profileId, ProfileSecrets secrets) async {
    _values[profileId] = secrets;
  }

  @override
  Future<void> delete(String profileId) async {
    _values.remove(profileId);
  }
}
