import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../models/film_catalog_item.dart';

/// TMDB 专用凭据，不复用服务器密码或主配置。
class TmdbCredentialStore {
  const TmdbCredentialStore();
  static const targetName = 'StreamPath/tmdb';

  Future<String?> read() async {
    if (!Platform.isWindows) return null;
    final target = targetName.toNativeUtf16();
    final result = calloc<Pointer<CREDENTIAL>>();
    try {
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
    final target = targetName.toNativeUtf16();
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
    final target = targetName.toNativeUtf16();
    try {
      if (CredDelete(target, CRED_TYPE_GENERIC, 0) != TRUE &&
          GetLastError() != 1168) {
        throw const FilmCatalogException('credentialStoreFailed');
      }
    } finally {
      calloc.free(target);
    }
  }
}
