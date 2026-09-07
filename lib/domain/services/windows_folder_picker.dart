import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/errors/app_exception.dart';

/// 使用 Windows IFileOpenDialog 选择文件夹。
class WindowsFolderPicker {
  const WindowsFolderPicker._();

  static const MethodChannel _channel = MethodChannel(
    'streampath/folder_picker',
  );

  static Future<String?> pickDirectory({required String title}) async {
    if (!Platform.isWindows) {
      throw AppException.config('当前平台不支持 Windows 文件夹选择器');
    }
    try {
      return await _channel.invokeMethod<String>(
        'pickDirectory',
        <String, Object>{'title': title},
      );
    } on PlatformException catch (error) {
      throw AppException.storage('无法打开 Windows 文件夹选择器', error);
    }
  }
}
