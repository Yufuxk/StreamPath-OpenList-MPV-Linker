import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../models/film_catalog_item.dart';

/// Windows 通用凭据文本，目标名称由各功能独立指定。
class WindowsCredentialTextStore {
  const WindowsCredentialTextStore(this._targetName, {this.libraryPath});
  final String _targetName;
  final String? libraryPath;
  static final _defaultLibrary = DynamicLibrary.open(
    '${File(Platform.resolvedExecutable).parent.path}/streampath_credentials.dll',
  );
  DynamicLibrary get _library =>
      libraryPath == null ? _defaultLibrary : DynamicLibrary.open(libraryPath!);

  Future<String?> read() async {
    if (!Platform.isWindows) return null;
    final target = _targetName.toNativeUtf16();
    final result = calloc<Pointer<CREDENTIAL>>();
    try {
      final error = _library
          .lookupFunction<
            Uint32 Function(Pointer<Utf16>, Pointer<Pointer<CREDENTIAL>>),
            int Function(Pointer<Utf16>, Pointer<Pointer<CREDENTIAL>>)
          >('sp_credential_read')(target, result);
      if (error == 1168) return null;
      if (error != 0) throw const FilmCatalogException('credentialStoreFailed');
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
      final error = _library
          .lookupFunction<
            Uint32 Function(Pointer<Utf16>),
            int Function(Pointer<Utf16>)
          >('sp_credential_delete')(target);
      if (error != 0 && error != 1168) {
        throw const FilmCatalogException('credentialStoreFailed');
      }
    } finally {
      calloc.free(target);
    }
  }
}
