import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 从现有 Windows 窗口通道读取可供界面使用的字体族。
abstract final class InstalledFonts {
  static const MethodChannel _channel = MethodChannel('streampath/appearance');

  static Future<List<String>> list() async {
    if (kIsWeb || !Platform.isWindows) return const [];
    final values = await _channel.invokeListMethod<String>('getInstalledFonts');
    if (values == null) {
      throw const FormatException('Windows font list response is invalid');
    }
    return values..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }
}
