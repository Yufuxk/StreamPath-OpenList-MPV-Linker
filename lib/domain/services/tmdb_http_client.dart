import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../../data/models/film_catalog_item.dart';

/// 只为 TMDB API 与图片读取系统代理，不影响网盘和播放器。
Dio createTmdbDio() =>
    Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      )
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()..findProxy = _findProxy,
      );

String _findProxy(Uri uri) {
  if (!Platform.isWindows) return HttpClient.findProxyFromEnvironment(uri);
  final config = calloc<_WindowsProxyConfig>();
  try {
    if (_getProxyConfig(config) == 0) {
      if (GetLastError() == 2) return HttpClient.findProxyFromEnvironment(uri);
      throw const FilmCatalogException('systemProxyFailed');
    }
    final proxy = config.ref.proxy;
    if (proxy == nullptr) return HttpClient.findProxyFromEnvironment(uri);
    return tmdbProxyDirective(
      uri,
      proxy: proxy.toDartString(),
      bypass: config.ref.bypass == nullptr
          ? ''
          : config.ref.bypass.toDartString(),
    );
  } finally {
    for (final pointer in [
      config.ref.autoConfigUrl,
      config.ref.proxy,
      config.ref.bypass,
    ]) {
      if (pointer != nullptr) GlobalFree(pointer);
    }
    calloc.free(config);
  }
}

/// Windows 手动代理支持统一地址、按协议地址及主机例外。
String tmdbProxyDirective(
  Uri uri, {
  required String proxy,
  String bypass = '',
}) {
  for (final entry in bypass.split(';').map((e) => e.trim())) {
    if (entry.isEmpty) continue;
    if (entry.toLowerCase() == '<local>') {
      if (!uri.host.contains('.')) return 'DIRECT';
    } else {
      final pattern = entry.split('*').map(RegExp.escape).join('.*');
      if (RegExp('^$pattern\$', caseSensitive: false).hasMatch(uri.host)) {
        return 'DIRECT';
      }
    }
  }
  final addresses = <String>[];
  for (final entry in proxy.split(';').map((e) => e.trim())) {
    if (entry.isEmpty) continue;
    final separator = entry.indexOf('=');
    if (separator < 0) {
      addresses.add(entry);
    } else if (entry.substring(0, separator).trim().toLowerCase() ==
        uri.scheme) {
      addresses.add(entry.substring(separator + 1).trim());
    }
  }
  return addresses.isEmpty
      ? 'DIRECT'
      : addresses.map((address) => 'PROXY $address').join('; ');
}

final class _WindowsProxyConfig extends Struct {
  @Int32()
  external int autoDetect;
  external Pointer<Utf16> autoConfigUrl;
  external Pointer<Utf16> proxy;
  external Pointer<Utf16> bypass;
}

final _getProxyConfig = DynamicLibrary.open('winhttp.dll')
    .lookupFunction<
      Int32 Function(Pointer<_WindowsProxyConfig>),
      int Function(Pointer<_WindowsProxyConfig>)
    >('WinHttpGetIEProxyConfigForCurrentUser');
