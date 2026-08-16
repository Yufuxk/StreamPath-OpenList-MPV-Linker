import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;

import '../../data/models/appearance_config.dart';
import 'window_appearance_status.dart';

export 'window_appearance_status.dart';

/// 窗口背景效果适配器，便于隔离和测试原生调用。
abstract interface class WindowAppearanceDriver {
  Future<WindowAppearanceCapabilities> queryCapabilities();

  Future<WindowAppearanceResult> apply(
    AppearanceConfig config,
    Brightness brightness,
  );
}

/// Windows 自适应窗口背景实现。
class AdaptiveWindowAppearanceDriver implements WindowAppearanceDriver {
  static const MethodChannel _appearanceChannel = MethodChannel(
    'streampath/appearance',
  );

  bool _initialized = false;

  @override
  Future<WindowAppearanceCapabilities> queryCapabilities() async {
    if (!Platform.isWindows) {
      return const WindowAppearanceCapabilities.unsupported();
    }
    final response = await _appearanceChannel.invokeMethod<Object?>(
      'getWindowCapabilities',
    );
    if (response is! Map) {
      throw const FormatException('Windows 外观能力返回格式无效');
    }
    return WindowAppearanceCapabilities.fromMap(response);
  }

  @override
  Future<WindowAppearanceResult> apply(
    AppearanceConfig config,
    Brightness brightness,
  ) async {
    final capabilities = await queryCapabilities();
    final isDark = brightness == Brightness.dark;
    if (!config.isGlass) {
      await _disableEffect(isDark);
      return WindowAppearanceResult.classic(
        capabilities,
        material: config.material,
      );
    }
    final blockingReason = capabilities.blockingReason;
    if (blockingReason != WindowAppearanceDegradation.none) {
      await _disableEffect(isDark);
      return WindowAppearanceResult(
        requestedStyle: InterfaceStyle.glass,
        requestedMaterial: config.material,
        actualBackdrop: WindowBackdropType.none,
        capabilities: capabilities.copyWith(
          systemBackdropType: WindowBackdropType.none,
        ),
        degradation: blockingReason,
      );
    }
    if (!_initialized) {
      await acrylic.Window.initialize();
      _initialized = true;
    }
    final alpha = (config.glassOpacity * 255).round();
    final tint = isDark
        ? Color.fromARGB(alpha, 18, 25, 34)
        : Color.fromARGB(alpha, 246, 248, 252);
    final resolvedMaterial = resolveWindowMaterial(
      config.material,
      capabilities,
    );
    await acrylic.Window.setEffect(
      effect: resolvedMaterial == WindowMaterialPreference.mica
          ? acrylic.WindowEffect.mica
          : acrylic.WindowEffect.acrylic,
      color: tint,
      dark: isDark,
    );
    WindowAppearanceCapabilities appliedCapabilities;
    try {
      appliedCapabilities = await queryCapabilities();
    } catch (_) {
      appliedCapabilities = capabilities;
    }
    final nativeBackdrop = appliedCapabilities.systemBackdropType;
    final actualBackdrop = resolveAppliedWindowBackdrop(
      nativeBackdrop: nativeBackdrop,
      resolvedMaterial: resolvedMaterial,
      supportsSystemBackdrop: appliedCapabilities.supportsSystemBackdrop,
    );
    final degradation = !actualBackdrop.isGlass
        ? WindowAppearanceDegradation.effectUnavailable
        : windowBackdropMatchesPreference(config.material, actualBackdrop)
        ? WindowAppearanceDegradation.none
        : WindowAppearanceDegradation.materialFallback;
    return WindowAppearanceResult(
      requestedStyle: InterfaceStyle.glass,
      requestedMaterial: config.material,
      actualBackdrop: actualBackdrop,
      capabilities: appliedCapabilities,
      degradation: degradation,
    );
  }

  Future<void> _disableEffect(bool isDark) async {
    if (!Platform.isWindows) return;
    if (_initialized) {
      await acrylic.Window.setEffect(
        effect: acrylic.WindowEffect.disabled,
        dark: isDark,
      );
    }
    // flutter_acrylic 1.1.4 未在新版 Windows 11 清理系统背景属性。
    await _appearanceChannel.invokeMethod<void>('resetWindowEffect', {
      'dark': isDark,
    });
  }
}

/// 只管理界面外观，不参与连接、浏览或播放状态。
class AppearanceController extends ChangeNotifier with WidgetsBindingObserver {
  AppearanceController({
    required AppearanceConfig initialConfig,
    WindowAppearanceDriver? driver,
  }) : _config = initialConfig,
       _driver = driver ?? AdaptiveWindowAppearanceDriver() {
    WidgetsBinding.instance.addObserver(this);
  }

  final WindowAppearanceDriver _driver;
  AppearanceConfig _config;
  WindowAppearanceCapabilities _capabilities =
      const WindowAppearanceCapabilities.undetected();
  WindowAppearanceResult? _lastResult;
  bool _checkingCapabilities = false;
  String? _capabilityError;
  Future<void>? _operationTail;

  AppearanceConfig get config => _config;
  WindowAppearanceCapabilities get capabilities => _capabilities;
  WindowAppearanceResult? get lastResult => _lastResult;
  bool get checkingCapabilities => _checkingCapabilities;
  String? get capabilityError => _capabilityError;

  /// 原生效果成功后才允许主题进入半透明状态。
  bool get glassActive =>
      _config.isGlass && (_lastResult?.glassActive ?? false);

  /// 读取 Windows 外观能力，不初始化窗口材质插件，也不修改用户配置。
  Future<void> refreshCapabilities() async {
    if (_checkingCapabilities) return;
    _checkingCapabilities = true;
    _capabilityError = null;
    notifyListeners();
    try {
      await _serializeAppearanceOperation(() async {
        final capabilities = await _driver.queryCapabilities();
        _capabilities = capabilities;
        if (_config.isGlass) {
          final actualBackdrop = resolveRefreshedWindowBackdrop(
            capabilities: capabilities,
            previousBackdrop: _lastResult?.actualBackdrop,
          );
          _lastResult = WindowAppearanceResult(
            requestedStyle: InterfaceStyle.glass,
            requestedMaterial: _config.material,
            actualBackdrop: actualBackdrop,
            capabilities: capabilities,
            degradation: actualBackdrop.isGlass
                ? windowBackdropMatchesPreference(
                        _config.material,
                        actualBackdrop,
                      )
                      ? WindowAppearanceDegradation.none
                      : WindowAppearanceDegradation.materialFallback
                : capabilities.canUseGlass
                ? WindowAppearanceDegradation.effectUnavailable
                : capabilities.blockingReason,
          );
        } else {
          _lastResult = WindowAppearanceResult.classic(
            capabilities,
            material: _config.material,
          );
        }
      });
    } catch (error) {
      _capabilityError = 'Windows 外观能力检测失败：$error';
      debugPrint(_capabilityError);
    } finally {
      _checkingCapabilities = false;
      notifyListeners();
    }
  }

  /// 首帧前恢复外观，默认样式不会初始化原生插件。
  Future<bool> restoreForStartup() async {
    if (!_config.isGlass) return true;
    final restored = await apply(_config);
    if (!restored) {
      _config = AppearanceConfig(
        material: _config.material,
        glassOpacity: _config.glassOpacity,
      );
      _lastResult = WindowAppearanceResult.classic(
        _capabilities,
        material: _config.material,
      );
      notifyListeners();
    }
    return restored;
  }

  /// 应用并切换界面外观；失败时保留当前有效样式。
  Future<bool> apply(AppearanceConfig next) =>
      _serializeAppearanceOperation(() async {
        if (_sameAppearance(next, _config) && (!next.isGlass || glassActive)) {
          return true;
        }
        final previous = _config;
        final previousResult = _lastResult;
        final disablingGlass = glassActive && !next.isGlass;
        if (disablingGlass) {
          // 先让 Flutter 绘制不透明背景，再关闭原生效果，避免短暂露出黑底。
          _config = next;
          _lastResult = WindowAppearanceResult.classic(
            _capabilities,
            material: next.material,
          );
          notifyListeners();
          await WidgetsBinding.instance.endOfFrame;
        }
        try {
          final result = await _driver.apply(next, _platformBrightness);
          _config = next;
          _capabilities = result.capabilities;
          _lastResult = result;
          _capabilityError = null;
        } catch (error) {
          debugPrint('应用窗口外观失败：$error');
          if (disablingGlass) {
            _config = previous;
            _lastResult = previousResult;
            notifyListeners();
          }
          return false;
        }
        notifyListeners();
        return true;
      });

  Future<T> _serializeAppearanceOperation<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    Future<void> run() async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }

    final previous = _operationTail;
    final current = previous == null ? run() : previous.then((_) => run());
    _operationTail = current;
    unawaited(
      current.whenComplete(() {
        if (identical(_operationTail, current)) _operationTail = null;
      }),
    );
    return completer.future;
  }

  @override
  void didChangePlatformBrightness() {
    if (!glassActive) return;
    unawaited(_refreshGlassTint());
  }

  Future<void> _refreshGlassTint() => _serializeAppearanceOperation(() async {
    if (!glassActive) return;
    try {
      final result = await _driver.apply(_config, _platformBrightness);
      _capabilities = result.capabilities;
      _lastResult = result;
      notifyListeners();
    } catch (error) {
      debugPrint('更新窗口明暗色调失败：$error');
    }
  });

  Brightness get _platformBrightness =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness;

  bool _sameAppearance(AppearanceConfig first, AppearanceConfig second) =>
      first.style == second.style &&
      first.material == second.material &&
      first.glassOpacity == second.glassOpacity;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
