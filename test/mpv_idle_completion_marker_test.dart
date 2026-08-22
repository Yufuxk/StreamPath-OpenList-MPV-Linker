import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/mpv_idle_completion_marker.dart';

void main() {
  test('idle 标记必须同时匹配最后播放项与本次 launch epoch', () {
    final marker = MpvIdleCompletionMarker.parse(const [
      '-1',
      '1',
      'epoch-new',
    ]);

    expect(marker, isNotNull);
    expect(
      marker!.matches(
        expectedLastPlaylistPos: 1,
        expectedLaunchEpoch: 'epoch-new',
      ),
      isTrue,
    );
    expect(
      marker.matches(
        expectedLastPlaylistPos: 0,
        expectedLaunchEpoch: 'epoch-new',
      ),
      isFalse,
    );
    expect(
      marker.matches(
        expectedLastPlaylistPos: 1,
        expectedLaunchEpoch: 'epoch-old',
      ),
      isFalse,
    );
  });

  test('旧版任意 -1、缺 epoch 与负播放项均不得触发终止', () {
    expect(MpvIdleCompletionMarker.parse(const ['-1', '']), isNull);
    expect(MpvIdleCompletionMarker.parse(const ['-1', '1', '']), isNull);
    expect(
      MpvIdleCompletionMarker.parse(const ['-1', '-1', 'epoch-new']),
      isNull,
    );
  });
}
