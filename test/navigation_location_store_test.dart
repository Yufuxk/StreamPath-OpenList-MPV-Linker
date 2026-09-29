import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/navigation_location_store.dart';
import 'package:streampath/data/models/appearance_config.dart';

void main() {
  test('侧边栏与目录记忆模式有稳定默认值和配置往返', () {
    final defaults = AppearanceConfig.fromJson(null);
    expect(defaults.sidebarMode, SidebarDisplayMode.pinned);
    expect(defaults.directoryMemoryMode, DirectoryMemoryMode.temporary);
    final restored = AppearanceConfig.fromJson(defaults.copyWith(
      sidebarMode: SidebarDisplayMode.autoHide,
      directoryMemoryMode: DirectoryMemoryMode.persistent,
    ).toJson());
    expect(restored.sidebarMode, SidebarDisplayMode.autoHide);
    expect(restored.directoryMemoryMode, DirectoryMemoryMode.persistent);
  });

  test('临时记录不落盘，持久记录重启恢复并可清除', () async {
    final temp = await Directory.systemTemp.createTemp('streampath_locations_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File(p.join(temp.path, 'locations.json'));
    final session = NavigationLocationStore(
      file,
      mode: DirectoryMemoryMode.temporary,
    );
    await session.remember(
      sourceId: 'local:a',
      kind: 'local',
      path: 'Series/Season 1',
    );
    expect(session.pathFor('local:a'), 'Series/Season 1');
    expect(await file.exists(), isFalse);

    await session.setMode(DirectoryMemoryMode.persistent);
    final restored = NavigationLocationStore(
      file,
      mode: DirectoryMemoryMode.persistent,
    );
    await restored.load();
    expect(restored.pathFor('local:a'), 'Series/Season 1');
    expect(restored.lastSource('local'), 'local:a');
    await restored.forget('local:a');
    expect(restored.pathFor('local:a'), isNull);
    await restored.setMode(DirectoryMemoryMode.temporary);
    expect(await file.exists(), isFalse);
  });
}
