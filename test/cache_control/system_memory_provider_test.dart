import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/providers/system_memory_provider.dart';

void main() {
  group('SystemMemoryProvider 契约', () {
    test('fake provider 返回注入值', () async {
      final fake = _FakeMemory(8 * 1024 * 1024 * 1024);
      expect(await fake.availableMemoryBytes(), 8 * 1024 * 1024 * 1024);
    });

    test('NullMemoryProvider 返回 null（引擎走兜底）', () async {
      expect(await const NullMemoryProvider().availableMemoryBytes(), isNull);
    });

    test('platformMemoryProvider 按平台选择实现', () {
      final provider = platformMemoryProvider();
      if (Platform.isWindows) {
        expect(provider, isA<WindowsSystemMemoryProvider>());
      } else {
        expect(provider, isA<NullMemoryProvider>());
      }
    });

    test('Windows 实现返回真实可用内存（>0）', () async {
      final bytes = await const WindowsSystemMemoryProvider()
          .availableMemoryBytes();
      if (Platform.isWindows) {
        expect(bytes, isNotNull);
        expect(bytes, greaterThan(0));
      } else {
        // 非 Windows 下 FFI 调用失败应被 catch 降级（不抛出）。
        expect(bytes, isNull);
      }
    });
  });
}

class _FakeMemory extends SystemMemoryProvider {
  _FakeMemory(this.bytes);

  final int bytes;

  @override
  Future<int?> availableMemoryBytes() async => bytes;
}
