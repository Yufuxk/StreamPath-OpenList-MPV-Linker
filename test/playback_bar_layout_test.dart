import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/widgets/playback_bar.dart';
import 'package:streampath/presentation/widgets/sp_icons.dart';

void main() {
  testWidgets('续播栏的跳过、播放和删除按钮等距排列', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackBar(
            title: '影片',
            dirLabel: '目录',
            icon: SPIcons.play,
            tooltip: '播放',
            deleting: false,
            onPressed: () {},
            onDelete: () {},
            onSkipSeason: () {},
            onSecondaryTapDown: (_) {},
          ),
        ),
      ),
    );

    final skip = tester.getCenter(find.byIcon(SPIcons.next));
    final play = tester.getCenter(find.byIcon(SPIcons.play));
    final delete = tester.getCenter(find.byIcon(SPIcons.delete));
    expect(play.dx - skip.dx, closeTo(delete.dx - play.dx, 0.1));
    expect(skip.dy, play.dy);
    expect(play.dy, delete.dy);
  });
}
