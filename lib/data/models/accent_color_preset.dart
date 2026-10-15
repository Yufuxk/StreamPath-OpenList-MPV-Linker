const defaultAccentColor = 0xFF3B6FE8;

/// 强调色预设；配置保存颜色值，可直接接入任意颜色选择器。
enum AccentColorPreset {
  blue(defaultAccentColor, '蓝色'),
  cyan(0xFF00B1FD, '青色'),
  green(0xFF04BB9F, '绿色'),
  lime(0xFFB6D70A, '青柠绿'),
  yellow(0xFFFECC39, '黄色'),
  orange(0xFFFE8067, '橙色'),
  pink(0xFFFF49AD, '粉色'),
  magenta(0xFFDC6ADB, '洋红色'),
  purple(0xFFA25BFF, '紫色'),
  white(0xFFFFFFFF, '白色');

  const AccentColorPreset(this.argb, this.label);

  final int argb;
  final String label;
}
