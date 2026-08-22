import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/audio_playback_history.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/presentation/presenters/playback_session_presenter.dart';

void main() {
  test('视频和音频会话独立排序、查找与删除', () {
    final presenter = PlaybackSessionPresenter();
    addTearDown(presenter.dispose);
    final later = DateTime(2026, 1, 2);
    final earlier = DateTime(2026, 1, 1);
    final laterVideo = PlaybackUiSession(
      PlaybackHistory(
        sessionId: 'video-later',
        dirCrumbs: const [],
        fileName: 'later.mkv',
        videoIndex: 0,
        updatedAt: later,
      ),
    );
    final earlierVideo = PlaybackUiSession(
      PlaybackHistory(
        sessionId: 'video-earlier',
        dirCrumbs: const [],
        fileName: 'earlier.mkv',
        videoIndex: 0,
        updatedAt: earlier,
      ),
    );
    final audio = AudioPlaybackUiSession(
      AudioPlaybackHistory(
        sessionId: 'audio',
        dirCrumbs: const [],
        fileName: 'track.flac',
        trackIndex: 0,
        updatedAt: later,
      ),
    );

    presenter.addVideoSession(laterVideo);
    presenter.addVideoSession(earlierVideo);
    presenter.addAudioSession(audio);

    expect(
      presenter.videoSessions.map((session) => session.history.sessionId),
      ['video-earlier', 'video-later'],
    );
    expect(presenter.videoSessionById('video-later'), same(laterVideo));
    expect(presenter.audioSessionById('audio'), same(audio));
    expect(
      () => presenter.videoSessions.add(laterVideo),
      throwsUnsupportedError,
    );

    presenter.removeVideoSession(earlierVideo);
    expect(presenter.videoSessions, [laterVideo]);
    expect(presenter.audioSessions, [audio]);
  });

  test('会话编号分轨且释放 Presenter 会取消轮询', () {
    final presenter = PlaybackSessionPresenter();
    final videoId = presenter.newVideoSessionId();
    final audioId = presenter.newAudioSessionId();
    final videoTimer = Timer.periodic(const Duration(days: 1), (_) {});
    final audioTimer = Timer.periodic(const Duration(days: 1), (_) {});
    presenter.videoMonitor = videoTimer;
    presenter.audioMonitor = audioTimer;

    expect(videoId, startsWith('play_'));
    expect(audioId, startsWith('audio_'));
    presenter.dispose();
    expect(videoTimer.isActive, isFalse);
    expect(audioTimer.isActive, isFalse);
  });
}
