import 'package:flutter_test/flutter_test.dart';

import 'package:streampath/data/models/player_config.dart';

/// StreamPath 基础 smoke 测试：
/// 验证核心模型与服务层在测试环境可正常构造/使用。
void main() {
  test('默认 mpv 配置含全部占位符', () {
    final def = PlayerConfig.defaultMpv();
    expect(def.name, 'mpv');
    expect(def.hasSubtitlePlaceholder, isTrue);
    expect(def.hasStartPlaceholder, isTrue);
  });
}
