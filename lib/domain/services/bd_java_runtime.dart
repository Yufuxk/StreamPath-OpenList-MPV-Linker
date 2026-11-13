import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';

/// Java 只注入菜单子进程；可写数据与程序运行库分开。
class BdJavaRuntime {
  BdJavaRuntime({String? root})
    : root =
          root ?? p.join(p.dirname(Platform.resolvedExecutable), 'lib', 'bdj');

  final String root;
  static const unavailable = '随附的 BD-J Java 运行时缺失或损坏，请重新安装或使用标题模式';

  Future<Map<String, String>?> environment(
    Directory writableRoot, {
    bool required = false,
  }) async {
    final manifest = File(p.join(root, 'runtime-manifest.json'));
    if (!await manifest.exists()) {
      if (required) throw AppException.config(unavailable);
      return null;
    }
    try {
      final data = jsonDecode(await manifest.readAsString());
      if (data is! Map<String, dynamic> ||
          data['files'] is! Map<String, dynamic> ||
          data['schema'] != 1 ||
          data['architecture'] != 'x64') {
        throw const FormatException('Invalid BD-J runtime manifest');
      }
      final files = data['files'] as Map;
      for (final name in [
        'java/bin/server/jvm.dll',
        'libbluray-j2se-1.5.0.jar',
        'libbluray-awt-j2se-1.5.0.jar',
      ]) {
        final file = File(p.join(root, name));
        if (!await file.exists() ||
            (await sha256.bind(file.openRead()).first).toString() !=
                files[name]) {
          throw const FormatException('BD-J runtime integrity check failed');
        }
      }
    } on FileSystemException catch (error) {
      throw AppException.config(unavailable, error);
    } on FormatException catch (error) {
      throw AppException.config(unavailable, error);
    }
    final cache = Directory(p.join(writableRoot.path, 'bdj', 'cache'));
    final persistent = Directory(
      p.join(writableRoot.path, 'bdj', 'persistent'),
    );
    await cache.create(recursive: true);
    await persistent.create(recursive: true);
    return {
      'JAVA_HOME': p.absolute(root, 'java'),
      'LIBBLURAY_CP': p.absolute(root, 'libbluray-j2se-1.5.0.jar'),
      'LIBBLURAY_CACHE_ROOT': cache.absolute.path,
      'LIBBLURAY_PERSISTENT_ROOT': persistent.absolute.path,
    };
  }
}
