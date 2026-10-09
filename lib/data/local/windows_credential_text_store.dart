import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../models/film_catalog_item.dart';

/// Windows 通用凭据文本，目标名称由各功能独立指定。
class WindowsCredentialTextStore {
  const WindowsCredentialTextStore(this._targetName);
  final String _targetName;

  Future<String?> read() async {
    if (!Platform.isWindows) return null;
    final target = _targetName.toNativeUtf16();
    final result = calloc<Pointer<CREDENTIAL>>();
    try {
      // 预先初始化 FFI 绑定，避免首次读取覆盖 CredRead 的错误码。
      GetLastError();
      if (CredRead(target, CRED_TYPE_GENERIC, 0, result) != TRUE) {
        if (GetLastError() == 1168) return null;
        throw const FilmCatalogException('credentialStoreFailed');
      }
      return utf8.decode(
        result.value.ref.CredentialBlob.asTypedList(
          result.value.ref.CredentialBlobSize,
        ),
      );
    } finally {
      if (result.value.address != 0) CredFree(result.value);
      calloc.free(result);
      calloc.free(target);
    }
  }

  Future<void> write(String token) async {
    if (!Platform.isWindows) {
      throw const FilmCatalogException('credentialStoreFailed');
    }
    final bytes = utf8.encode(token.trim());
    if (bytes.isEmpty || bytes.length > 2560) {
      throw const FilmCatalogException('invalidToken');
    }
    final target = _targetName.toNativeUtf16();
    final user = 'StreamPath'.toNativeUtf16();
    final blob = calloc<Uint8>(bytes.length)
      ..asTypedList(bytes.length).setAll(0, bytes);
    final credential = calloc<CREDENTIAL>()
      ..ref.Type = CRED_TYPE_GENERIC
      ..ref.TargetName = target
      ..ref.UserName = user
      ..ref.Persist = CRED_PERSIST_LOCAL_MACHINE
      ..ref.CredentialBlob = blob
      ..ref.CredentialBlobSize = bytes.length;
    try {
      GetLastError();
      if (CredWrite(credential, 0) != TRUE) {
        throw const FilmCatalogException('credentialStoreFailed');
      }
    } finally {
      blob.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(credential);
      calloc.free(blob);
      calloc.free(user);
      calloc.free(target);
    }
  }

  Future<void> delete() async {
    if (!Platform.isWindows) return;
    final target = _targetName.toNativeUtf16();
    try {
      GetLastError();
      if (CredDelete(target, CRED_TYPE_GENERIC, 0) != TRUE &&
          GetLastError() != 1168) {
        throw const FilmCatalogException('credentialStoreFailed');
      }
    } finally {
      calloc.free(target);
    }
  }
}
