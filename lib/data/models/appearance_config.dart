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

enum SidebarDisplayMode { pinned, autoHide }

enum DirectoryMemoryMode { temporary, persistent }

/// 界面外观配置。
class AppearanceConfig {
  const AppearanceConfig({
    this.style = InterfaceStyle.classic,
    this.material = WindowMaterialPreference.automatic,
    this.glassOpacity = defaultGlassOpacity,
    this.fontFamily,
    this.sidebarMode = SidebarDisplayMode.pinned,
    this.directoryMemoryMode = DirectoryMemoryMode.temporary,
  });

  static const double defaultGlassOpacity = 0.60;
  static const double minGlassOpacity = 0.60;
  static const double maxGlassOpacity = 0.95;

  final InterfaceStyle style;

  final WindowMaterialPreference material;

  /// 磨砂背景的不透明度，数值越高背景越实。
  final double glassOpacity;

  /// 界面字体；null 表示使用系统推荐的 Segoe UI 系列。
  final String? fontFamily;
  final SidebarDisplayMode sidebarMode;
  final DirectoryMemoryMode directoryMemoryMode;

  bool get isGlass => style == InterfaceStyle.glass;

  static AppearanceConfig defaults() => const AppearanceConfig();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'style': style.name,
    'material': material.name,
    'glassOpacity': glassOpacity,
    'fontFamily': fontFamily,
    'sidebarMode': sidebarMode.name,
    'directoryMemoryMode': directoryMemoryMode.name,
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
      fontFamily:
          json['fontFamily'] is String &&
              (json['fontFamily'] as String).isNotEmpty
          ? json['fontFamily'] as String
          : null,
      sidebarMode: json['sidebarMode'] == SidebarDisplayMode.autoHide.name
          ? SidebarDisplayMode.autoHide
          : SidebarDisplayMode.pinned,
      directoryMemoryMode:
          json['directoryMemoryMode'] == DirectoryMemoryMode.persistent.name
          ? DirectoryMemoryMode.persistent
          : DirectoryMemoryMode.temporary,
    );
  }

  AppearanceConfig copyWith({
    SidebarDisplayMode? sidebarMode,
    DirectoryMemoryMode? directoryMemoryMode,
  }) => AppearanceConfig(
    style: style,
    material: material,
    glassOpacity: glassOpacity,
    fontFamily: fontFamily,
    sidebarMode: sidebarMode ?? this.sidebarMode,
    directoryMemoryMode: directoryMemoryMode ?? this.directoryMemoryMode,
  );
}
