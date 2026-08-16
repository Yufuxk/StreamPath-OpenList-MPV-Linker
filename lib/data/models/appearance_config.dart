/// 可选的界面样式。
enum InterfaceStyle {
  /// 保留现有的不透明界面。
  classic,

  /// 使用 Windows 窗口级磨砂材质。
  glass,
}

/// 磨砂界面使用的 Windows 窗口材质偏好。
enum WindowMaterialPreference {
  /// Windows 11 优先使用 Mica，其他受支持版本使用 Acrylic。
  automatic,

  /// 始终请求 Acrylic。
  acrylic,

  /// 优先请求 Mica，不支持时回退 Acrylic。
  mica,
}

/// 界面外观配置。
class AppearanceConfig {
  const AppearanceConfig({
    this.style = InterfaceStyle.classic,
    this.material = WindowMaterialPreference.automatic,
    this.glassOpacity = defaultGlassOpacity,
  });

  static const double defaultGlassOpacity = 0.82;
  static const double minGlassOpacity = 0.60;
  static const double maxGlassOpacity = 0.95;

  final InterfaceStyle style;

  final WindowMaterialPreference material;

  /// 磨砂背景的不透明度，数值越高背景越实。
  final double glassOpacity;

  bool get isGlass => style == InterfaceStyle.glass;

  static AppearanceConfig defaults() => const AppearanceConfig();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'style': style.name,
    'material': material.name,
    'glassOpacity': glassOpacity,
  };

  factory AppearanceConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults();
    final style = json['style'] == InterfaceStyle.glass.name
        ? InterfaceStyle.glass
        : InterfaceStyle.classic;
    final material = switch (json['material']) {
      'automatic' => WindowMaterialPreference.automatic,
      'acrylic' => WindowMaterialPreference.acrylic,
      'mica' => WindowMaterialPreference.mica,
      null when style == InterfaceStyle.glass =>
        WindowMaterialPreference.acrylic,
      _ => WindowMaterialPreference.automatic,
    };
    final rawOpacity = json['glassOpacity'];
    final parsedOpacity = rawOpacity is num
        ? rawOpacity.toDouble()
        : double.tryParse(rawOpacity?.toString() ?? '');
    final opacity = (parsedOpacity ?? defaultGlassOpacity)
        .clamp(minGlassOpacity, maxGlassOpacity)
        .toDouble();
    return AppearanceConfig(
      style: style,
      material: material,
      glassOpacity: opacity,
    );
  }
}
