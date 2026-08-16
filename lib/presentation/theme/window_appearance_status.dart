import '../../data/models/appearance_config.dart';

/// Windows 当前实际使用的窗口背景材质。
enum WindowBackdropType {
  none,
  legacyAcrylic,
  systemAcrylic,
  mica,
  tabbed,
  unknown,
}

extension WindowBackdropTypeLabel on WindowBackdropType {
  bool get isGlass =>
      this == WindowBackdropType.legacyAcrylic ||
      this == WindowBackdropType.systemAcrylic ||
      this == WindowBackdropType.mica ||
      this == WindowBackdropType.tabbed;

  String get label => switch (this) {
    WindowBackdropType.none => '无（不透明界面）',
    WindowBackdropType.legacyAcrylic => 'Acrylic（兼容模式）',
    WindowBackdropType.systemAcrylic => 'Acrylic（系统材质）',
    WindowBackdropType.mica => 'Mica',
    WindowBackdropType.tabbed => 'Tabbed Mica',
    WindowBackdropType.unknown => '尚未识别',
  };

  static WindowBackdropType fromNativeValue(int value) => switch (value) {
    1 => WindowBackdropType.none,
    2 => WindowBackdropType.mica,
    3 => WindowBackdropType.systemAcrylic,
    4 => WindowBackdropType.tabbed,
    _ => WindowBackdropType.unknown,
  };
}

/// 磨砂效果未实际生效时的原因。
enum WindowAppearanceDegradation {
  none,
  unsupportedPlatform,
  unsupportedWindowsVersion,
  compositionDisabled,
  transparencyDisabled,
  highContrast,
  remoteSession,
  materialFallback,
  effectUnavailable,
}

extension WindowAppearanceDegradationLabel on WindowAppearanceDegradation {
  String get message => switch (this) {
    WindowAppearanceDegradation.none => '当前未发生降级。',
    WindowAppearanceDegradation.unsupportedPlatform =>
      '当前平台不支持 Windows 窗口级磨砂材质。',
    WindowAppearanceDegradation.unsupportedWindowsVersion =>
      '当前 Windows 版本不支持所需的窗口材质。',
    WindowAppearanceDegradation.compositionDisabled =>
      'Windows 桌面合成当前不可用，界面已回退为不透明显示。',
    WindowAppearanceDegradation.transparencyDisabled =>
      'Windows“透明效果”已关闭，界面已回退为不透明显示。',
    WindowAppearanceDegradation.highContrast =>
      'Windows 高对比度模式已开启，界面已回退为不透明显示。',
    WindowAppearanceDegradation.remoteSession => '远程桌面会话不保证窗口磨砂效果，界面已回退为不透明显示。',
    WindowAppearanceDegradation.materialFallback =>
      '所选材质在当前系统不可用，已自动使用另一种可用窗口材质。',
    WindowAppearanceDegradation.effectUnavailable => '系统允许透明效果，但本次窗口材质未能生效。',
  };
}

/// Runner 返回的 Windows 外观能力快照。
class WindowAppearanceCapabilities {
  const WindowAppearanceCapabilities({
    required this.isDetected,
    required this.platformSupported,
    required this.versionMajor,
    required this.versionMinor,
    required this.buildNumber,
    required this.compositionEnabled,
    required this.transparencyEnabled,
    required this.highContrast,
    required this.remoteSession,
    required this.supportsLegacyAcrylic,
    required this.supportsMica,
    required this.supportsSystemBackdrop,
    required this.systemBackdropType,
  });

  const WindowAppearanceCapabilities.undetected()
    : isDetected = false,
      platformSupported = false,
      versionMajor = 0,
      versionMinor = 0,
      buildNumber = 0,
      compositionEnabled = false,
      transparencyEnabled = false,
      highContrast = false,
      remoteSession = false,
      supportsLegacyAcrylic = false,
      supportsMica = false,
      supportsSystemBackdrop = false,
      systemBackdropType = WindowBackdropType.unknown;

  const WindowAppearanceCapabilities.unsupported()
    : isDetected = true,
      platformSupported = false,
      versionMajor = 0,
      versionMinor = 0,
      buildNumber = 0,
      compositionEnabled = false,
      transparencyEnabled = false,
      highContrast = false,
      remoteSession = false,
      supportsLegacyAcrylic = false,
      supportsMica = false,
      supportsSystemBackdrop = false,
      systemBackdropType = WindowBackdropType.none;

  factory WindowAppearanceCapabilities.fromMap(Map<Object?, Object?> map) {
    int readInt(String key) => (map[key] as num?)?.toInt() ?? 0;
    bool readBool(String key) => map[key] == true;

    return WindowAppearanceCapabilities(
      isDetected: true,
      platformSupported: readBool('platformSupported'),
      versionMajor: readInt('versionMajor'),
      versionMinor: readInt('versionMinor'),
      buildNumber: readInt('buildNumber'),
      compositionEnabled: readBool('compositionEnabled'),
      transparencyEnabled: readBool('transparencyEnabled'),
      highContrast: readBool('highContrast'),
      remoteSession: readBool('remoteSession'),
      supportsLegacyAcrylic: readBool('supportsLegacyAcrylic'),
      supportsMica: readBool('supportsMica'),
      supportsSystemBackdrop: readBool('supportsSystemBackdrop'),
      systemBackdropType: WindowBackdropTypeLabel.fromNativeValue(
        readInt('systemBackdropType'),
      ),
    );
  }

  final bool isDetected;
  final bool platformSupported;
  final int versionMajor;
  final int versionMinor;
  final int buildNumber;
  final bool compositionEnabled;
  final bool transparencyEnabled;
  final bool highContrast;
  final bool remoteSession;
  final bool supportsLegacyAcrylic;
  final bool supportsMica;
  final bool supportsSystemBackdrop;
  final WindowBackdropType systemBackdropType;

  WindowAppearanceDegradation get blockingReason {
    if (!platformSupported) {
      return WindowAppearanceDegradation.unsupportedPlatform;
    }
    if (!supportsLegacyAcrylic) {
      return WindowAppearanceDegradation.unsupportedWindowsVersion;
    }
    if (highContrast) {
      return WindowAppearanceDegradation.highContrast;
    }
    if (!compositionEnabled) {
      return WindowAppearanceDegradation.compositionDisabled;
    }
    if (!transparencyEnabled) {
      return WindowAppearanceDegradation.transparencyDisabled;
    }
    if (remoteSession) {
      return WindowAppearanceDegradation.remoteSession;
    }
    return WindowAppearanceDegradation.none;
  }

  bool get canUseGlass =>
      isDetected && blockingReason == WindowAppearanceDegradation.none;

  String get windowsVersionLabel {
    if (!isDetected) return '尚未检测';
    if (!platformSupported) return '非 Windows 平台';
    return 'Windows $versionMajor.$versionMinor（内部版本 $buildNumber）';
  }

  String get transparencyStatusLabel {
    if (!isDetected) return '尚未检测';
    if (!platformSupported) return '不适用';
    final transparency = transparencyEnabled ? '已开启' : '已关闭';
    final contrast = highContrast ? '已开启' : '未开启';
    return '透明效果：$transparency · 高对比度：$contrast';
  }

  String get availabilityLabel {
    if (!isDetected) return '等待检测';
    if (!canUseGlass) return blockingReason.message;
    return supportsMica ? '可使用 Mica 与 Acrylic 窗口材质' : '可使用 Acrylic 窗口材质';
  }

  String get supportedMaterialsLabel {
    if (!isDetected) return '尚未检测';
    if (!supportsLegacyAcrylic) return '无';
    return supportsMica ? 'Mica · Acrylic' : 'Acrylic';
  }

  WindowAppearanceCapabilities copyWith({
    WindowBackdropType? systemBackdropType,
  }) => WindowAppearanceCapabilities(
    isDetected: isDetected,
    platformSupported: platformSupported,
    versionMajor: versionMajor,
    versionMinor: versionMinor,
    buildNumber: buildNumber,
    compositionEnabled: compositionEnabled,
    transparencyEnabled: transparencyEnabled,
    highContrast: highContrast,
    remoteSession: remoteSession,
    supportsLegacyAcrylic: supportsLegacyAcrylic,
    supportsMica: supportsMica,
    supportsSystemBackdrop: supportsSystemBackdrop,
    systemBackdropType: systemBackdropType ?? this.systemBackdropType,
  );
}

/// 一次外观应用的请求值、实际结果与降级信息。
class WindowAppearanceResult {
  const WindowAppearanceResult({
    required this.requestedStyle,
    required this.requestedMaterial,
    required this.actualBackdrop,
    required this.capabilities,
    this.degradation = WindowAppearanceDegradation.none,
  });

  factory WindowAppearanceResult.classic(
    WindowAppearanceCapabilities capabilities, {
    WindowMaterialPreference material = WindowMaterialPreference.automatic,
  }) => WindowAppearanceResult(
    requestedStyle: InterfaceStyle.classic,
    requestedMaterial: material,
    actualBackdrop: WindowBackdropType.none,
    capabilities: capabilities,
  );

  final InterfaceStyle requestedStyle;
  final WindowMaterialPreference requestedMaterial;
  final WindowBackdropType actualBackdrop;
  final WindowAppearanceCapabilities capabilities;
  final WindowAppearanceDegradation degradation;

  bool get glassActive =>
      requestedStyle == InterfaceStyle.glass && actualBackdrop.isGlass;

  bool get isDegraded =>
      requestedStyle == InterfaceStyle.glass &&
      degradation != WindowAppearanceDegradation.none;

  String get actualEffectLabel {
    if (requestedStyle == InterfaceStyle.classic) return '默认不透明样式';
    return actualBackdrop.label;
  }
}

/// 根据系统能力把用户材质偏好解析为本次应请求的具体材质。
WindowMaterialPreference resolveWindowMaterial(
  WindowMaterialPreference preference,
  WindowAppearanceCapabilities capabilities,
) => switch (preference) {
  WindowMaterialPreference.automatic =>
    capabilities.supportsMica
        ? WindowMaterialPreference.mica
        : WindowMaterialPreference.acrylic,
  WindowMaterialPreference.mica =>
    capabilities.supportsMica
        ? WindowMaterialPreference.mica
        : WindowMaterialPreference.acrylic,
  WindowMaterialPreference.acrylic => WindowMaterialPreference.acrylic,
};

bool windowBackdropMatchesPreference(
  WindowMaterialPreference preference,
  WindowBackdropType backdrop,
) => switch (preference) {
  WindowMaterialPreference.automatic => backdrop.isGlass,
  WindowMaterialPreference.acrylic =>
    backdrop == WindowBackdropType.legacyAcrylic ||
        backdrop == WindowBackdropType.systemAcrylic,
  WindowMaterialPreference.mica => backdrop == WindowBackdropType.mica,
};

/// 新版系统以 DWM 查询值为准；旧版接口不可查询时按成功请求的材质推断。
WindowBackdropType resolveAppliedWindowBackdrop({
  required WindowBackdropType nativeBackdrop,
  required WindowMaterialPreference resolvedMaterial,
  required bool supportsSystemBackdrop,
}) {
  if (nativeBackdrop.isGlass) return nativeBackdrop;
  if (supportsSystemBackdrop) return WindowBackdropType.none;
  return resolvedMaterial == WindowMaterialPreference.mica
      ? WindowBackdropType.mica
      : WindowBackdropType.legacyAcrylic;
}

/// 能力刷新不重新应用材质：新版系统读取 DWM 实际值，旧版沿用已确认结果。
WindowBackdropType resolveRefreshedWindowBackdrop({
  required WindowAppearanceCapabilities capabilities,
  WindowBackdropType? previousBackdrop,
}) {
  if (!capabilities.canUseGlass) return WindowBackdropType.none;
  if (capabilities.supportsSystemBackdrop) {
    return capabilities.systemBackdropType.isGlass
        ? capabilities.systemBackdropType
        : WindowBackdropType.none;
  }
  return previousBackdrop?.isGlass == true
      ? previousBackdrop!
      : WindowBackdropType.none;
}
