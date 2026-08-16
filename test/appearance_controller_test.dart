import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/presentation/theme/appearance_controller.dart';

const _supportedCapabilities = WindowAppearanceCapabilities(
  isDetected: true,
  platformSupported: true,
  versionMajor: 10,
  versionMinor: 0,
  buildNumber: 26100,
  compositionEnabled: true,
  transparencyEnabled: true,
  highContrast: false,
  remoteSession: false,
  supportsLegacyAcrylic: true,
  supportsMica: true,
  supportsSystemBackdrop: true,
  systemBackdropType: WindowBackdropType.systemAcrylic,
);

void main() {
  test('Runner 能力数据映射 Windows 版本与系统 Acrylic', () {
    final capabilities = WindowAppearanceCapabilities.fromMap({
      'platformSupported': true,
      'versionMajor': 10,
      'versionMinor': 0,
      'buildNumber': 26100,
      'compositionEnabled': true,
      'transparencyEnabled': true,
      'highContrast': false,
      'remoteSession': false,
      'supportsLegacyAcrylic': true,
      'supportsMica': true,
      'supportsSystemBackdrop': true,
      'systemBackdropType': 3,
    });

    expect(capabilities.windowsVersionLabel, 'Windows 10.0（内部版本 26100）');
    expect(capabilities.canUseGlass, isTrue);
    expect(
      resolveWindowMaterial(WindowMaterialPreference.automatic, capabilities),
      WindowMaterialPreference.mica,
    );
    expect(capabilities.systemBackdropType, WindowBackdropType.systemAcrylic);
    expect(
      resolveAppliedWindowBackdrop(
        nativeBackdrop: WindowBackdropType.none,
        resolvedMaterial: WindowMaterialPreference.mica,
        supportsSystemBackdrop: true,
      ),
      WindowBackdropType.none,
      reason: '新版系统可查询实际结果时不能用请求成功代替材质生效',
    );
    expect(
      resolveAppliedWindowBackdrop(
        nativeBackdrop: WindowBackdropType.unknown,
        resolvedMaterial: WindowMaterialPreference.mica,
        supportsSystemBackdrop: false,
      ),
      WindowBackdropType.mica,
      reason: '旧版 Mica 接口不可查询，只能在调用成功后按请求材质推断',
    );
  });

  testWidgets('默认样式启动时不初始化窗口特效', (tester) async {
    final driver = _FakeWindowAppearanceDriver();
    final controller = AppearanceController(
      initialConfig: AppearanceConfig.defaults(),
      driver: driver,
    );
    addTearDown(controller.dispose);

    expect(await controller.restoreForStartup(), isTrue);
    expect(driver.applied, isEmpty);
    expect(driver.queryCount, 0);
    expect(controller.glassActive, isFalse);
  });

  testWidgets('自动材质在 Windows 11 使用 Mica 并激活磨砂主题', (tester) async {
    final driver = _FakeWindowAppearanceDriver();
    const glass = AppearanceConfig(
      style: InterfaceStyle.glass,
      glassOpacity: 0.74,
    );
    final controller = AppearanceController(
      initialConfig: glass,
      driver: driver,
    );
    addTearDown(controller.dispose);

    expect(controller.glassActive, isFalse);
    expect(await controller.restoreForStartup(), isTrue);
    expect(controller.glassActive, isTrue);
    expect(controller.config.glassOpacity, 0.74);
    expect(driver.applied, [glass]);
    expect(controller.lastResult?.actualBackdrop, WindowBackdropType.mica);
  });

  testWidgets('显式 Acrylic 在支持 Mica 的系统仍保持 Acrylic', (tester) async {
    final driver = _FakeWindowAppearanceDriver();
    const glass = AppearanceConfig(
      style: InterfaceStyle.glass,
      material: WindowMaterialPreference.acrylic,
    );
    final controller = AppearanceController(
      initialConfig: glass,
      driver: driver,
    );
    addTearDown(controller.dispose);

    expect(await controller.restoreForStartup(), isTrue);
    expect(
      controller.lastResult?.actualBackdrop,
      WindowBackdropType.systemAcrylic,
    );
    expect(
      controller.lastResult?.degradation,
      WindowAppearanceDegradation.none,
    );
  });

  testWidgets('显式 Mica 在 Windows 10 回退 Acrylic 并保留偏好', (tester) async {
    final driver = _FakeWindowAppearanceDriver(
      capabilities: const WindowAppearanceCapabilities(
        isDetected: true,
        platformSupported: true,
        versionMajor: 10,
        versionMinor: 0,
        buildNumber: 19045,
        compositionEnabled: true,
        transparencyEnabled: true,
        highContrast: false,
        remoteSession: false,
        supportsLegacyAcrylic: true,
        supportsMica: false,
        supportsSystemBackdrop: false,
        systemBackdropType: WindowBackdropType.unknown,
      ),
    );
    const glass = AppearanceConfig(
      style: InterfaceStyle.glass,
      material: WindowMaterialPreference.mica,
    );
    final controller = AppearanceController(
      initialConfig: glass,
      driver: driver,
    );
    addTearDown(controller.dispose);

    expect(await controller.restoreForStartup(), isTrue);
    expect(controller.config.material, WindowMaterialPreference.mica);
    expect(controller.glassActive, isTrue);
    expect(
      controller.lastResult?.actualBackdrop,
      WindowBackdropType.legacyAcrylic,
    );
    expect(
      controller.lastResult?.degradation,
      WindowAppearanceDegradation.materialFallback,
    );

    await controller.refreshCapabilities();
    expect(controller.glassActive, isTrue);
    expect(
      controller.lastResult?.actualBackdrop,
      WindowBackdropType.legacyAcrylic,
      reason: '旧版系统无法读取 DWM 材质属性时应沿用已经确认的 Acrylic 结果',
    );
  });

  testWidgets('高对比度开启时保留磨砂选择并明确降级', (tester) async {
    final driver = _FakeWindowAppearanceDriver(
      capabilities: const WindowAppearanceCapabilities(
        isDetected: true,
        platformSupported: true,
        versionMajor: 10,
        versionMinor: 0,
        buildNumber: 26100,
        compositionEnabled: true,
        transparencyEnabled: true,
        highContrast: true,
        remoteSession: false,
        supportsLegacyAcrylic: true,
        supportsMica: true,
        supportsSystemBackdrop: true,
        systemBackdropType: WindowBackdropType.none,
      ),
    );
    const glass = AppearanceConfig(style: InterfaceStyle.glass);
    final controller = AppearanceController(
      initialConfig: glass,
      driver: driver,
    );
    addTearDown(controller.dispose);

    expect(await controller.restoreForStartup(), isTrue);
    expect(controller.config.style, InterfaceStyle.glass);
    expect(controller.glassActive, isFalse);
    expect(
      controller.lastResult?.degradation,
      WindowAppearanceDegradation.highContrast,
    );
  });

  testWidgets('能力刷新只读取系统状态而不应用效果', (tester) async {
    final driver = _FakeWindowAppearanceDriver();
    final controller = AppearanceController(
      initialConfig: AppearanceConfig.defaults(),
      driver: driver,
    );
    addTearDown(controller.dispose);

    await controller.refreshCapabilities();

    expect(driver.queryCount, 1);
    expect(driver.applied, isEmpty);
    expect(controller.capabilities.buildNumber, 26100);
    expect(controller.lastResult?.actualBackdrop, WindowBackdropType.none);
  });

  testWidgets('能力刷新以新版 Windows 当前实际材质为准', (tester) async {
    final driver = _FakeWindowAppearanceDriver();
    final controller = AppearanceController(
      initialConfig: const AppearanceConfig(style: InterfaceStyle.glass),
      driver: driver,
    );
    addTearDown(controller.dispose);

    expect(await controller.restoreForStartup(), isTrue);
    expect(controller.lastResult?.actualBackdrop, WindowBackdropType.mica);

    driver.capabilities = driver.capabilities.copyWith(
      systemBackdropType: WindowBackdropType.none,
    );
    await controller.refreshCapabilities();

    expect(controller.glassActive, isFalse);
    expect(
      controller.lastResult?.degradation,
      WindowAppearanceDegradation.effectUnavailable,
    );
  });

  testWidgets('能力检测与材质应用按发起顺序串行执行', (tester) async {
    final driver = _BlockingWindowAppearanceDriver();
    final controller = AppearanceController(
      initialConfig: AppearanceConfig.defaults(),
      driver: driver,
    );
    addTearDown(controller.dispose);

    final refresh = controller.refreshCapabilities();
    await driver.queryStarted.future;
    final apply = controller.apply(
      const AppearanceConfig(style: InterfaceStyle.glass),
    );
    await tester.pump();

    expect(driver.applyStarted, isFalse);
    driver.releaseQuery.complete();
    await refresh;
    expect(await apply, isTrue);
    expect(driver.maxConcurrentOperations, 1);
    expect(controller.lastResult?.actualBackdrop, WindowBackdropType.mica);
  });

  testWidgets('原生效果失败时回退默认界面', (tester) async {
    final driver = _FakeWindowAppearanceDriver(shouldFail: true);
    final controller = AppearanceController(
      initialConfig: const AppearanceConfig(
        style: InterfaceStyle.glass,
        glassOpacity: 0.68,
      ),
      driver: driver,
    );
    addTearDown(controller.dispose);

    expect(await controller.restoreForStartup(), isFalse);
    expect(controller.config.style, InterfaceStyle.classic);
    expect(controller.config.glassOpacity, 0.68);
    expect(controller.glassActive, isFalse);
  });
}

class _FakeWindowAppearanceDriver implements WindowAppearanceDriver {
  _FakeWindowAppearanceDriver({
    this.shouldFail = false,
    this.capabilities = _supportedCapabilities,
  });

  final bool shouldFail;
  WindowAppearanceCapabilities capabilities;
  final List<AppearanceConfig> applied = [];
  int queryCount = 0;

  @override
  Future<WindowAppearanceCapabilities> queryCapabilities() async {
    queryCount++;
    return capabilities;
  }

  @override
  Future<WindowAppearanceResult> apply(
    AppearanceConfig config,
    Brightness brightness,
  ) async {
    applied.add(config);
    if (shouldFail) throw StateError('test failure');
    if (!config.isGlass) {
      return WindowAppearanceResult.classic(capabilities);
    }
    final degradation = capabilities.blockingReason;
    final resolvedMaterial = resolveWindowMaterial(
      config.material,
      capabilities,
    );
    final actualBackdrop = degradation != WindowAppearanceDegradation.none
        ? WindowBackdropType.none
        : resolvedMaterial == WindowMaterialPreference.mica
        ? WindowBackdropType.mica
        : capabilities.supportsSystemBackdrop
        ? WindowBackdropType.systemAcrylic
        : WindowBackdropType.legacyAcrylic;
    return WindowAppearanceResult(
      requestedStyle: InterfaceStyle.glass,
      requestedMaterial: config.material,
      actualBackdrop: actualBackdrop,
      capabilities: capabilities,
      degradation: degradation != WindowAppearanceDegradation.none
          ? degradation
          : windowBackdropMatchesPreference(config.material, actualBackdrop)
          ? WindowAppearanceDegradation.none
          : WindowAppearanceDegradation.materialFallback,
    );
  }
}

class _BlockingWindowAppearanceDriver implements WindowAppearanceDriver {
  final queryStarted = Completer<void>();
  final releaseQuery = Completer<void>();
  bool applyStarted = false;
  int _activeOperations = 0;
  int maxConcurrentOperations = 0;

  void _startOperation() {
    _activeOperations++;
    if (_activeOperations > maxConcurrentOperations) {
      maxConcurrentOperations = _activeOperations;
    }
  }

  void _finishOperation() => _activeOperations--;

  @override
  Future<WindowAppearanceCapabilities> queryCapabilities() async {
    _startOperation();
    queryStarted.complete();
    await releaseQuery.future;
    _finishOperation();
    return _supportedCapabilities.copyWith(
      systemBackdropType: WindowBackdropType.none,
    );
  }

  @override
  Future<WindowAppearanceResult> apply(
    AppearanceConfig config,
    Brightness brightness,
  ) async {
    _startOperation();
    applyStarted = true;
    _finishOperation();
    return WindowAppearanceResult(
      requestedStyle: InterfaceStyle.glass,
      requestedMaterial: config.material,
      actualBackdrop: WindowBackdropType.mica,
      capabilities: _supportedCapabilities.copyWith(
        systemBackdropType: WindowBackdropType.mica,
      ),
    );
  }
}
