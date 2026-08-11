import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// 系统可用内存提供者（抽象接口，便于测试注入 fake）。
///
/// 内存数据仅用于 Layer 1 安全限制（缓存预算），获取失败返回 null，
/// 由引擎走 1GiB 保守兜底，绝不阻断播放。
abstract class SystemMemoryProvider {
  const SystemMemoryProvider();

  /// 可用物理内存（字节）；平台不支持或获取失败返回 null。
  Future<int?> availableMemoryBytes();
}

/// 平台不支持的占位实现（非 Windows 返回 null）。
class NullMemoryProvider extends SystemMemoryProvider {
  const NullMemoryProvider();

  @override
  Future<int?> availableMemoryBytes() async => null;
}

/// Windows 实现：`GlobalMemoryStatusEx` → `ullAvailPhys`。
///
/// 通过 win32 包（项目既有依赖）调用，模块内自包含，不依赖项目
/// 其他业务模块。任何 FFI 异常都降级返回 null。
class WindowsSystemMemoryProvider extends SystemMemoryProvider {
  const WindowsSystemMemoryProvider();

  @override
  Future<int?> availableMemoryBytes() async {
    // 注意：CallocAllocator.allocate 的第一个参数是 byteCount（字节数），
    // 不是元素个数！曾误写 allocate(1) 只分配 1 字节，GlobalMemoryStatusEx
    // 写入 64 字节导致堆越界损坏 → 间歇性 ACCESS_VIOLATION（应用闪退）。
    final status = calloc.allocate<MEMORYSTATUSEX>(sizeOf<MEMORYSTATUSEX>());
    try {
      status.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
      if (GlobalMemoryStatusEx(status) == 0) return null;
      final avail = status.ref.ullAvailPhys;
      return avail > 0 ? avail : null;
    } catch (_) {
      return null;
    } finally {
      calloc.free(status);
    }
  }
}

/// 按当前平台选择实现。
SystemMemoryProvider platformMemoryProvider() => Platform.isWindows
    ? const WindowsSystemMemoryProvider()
    : const NullMemoryProvider();
