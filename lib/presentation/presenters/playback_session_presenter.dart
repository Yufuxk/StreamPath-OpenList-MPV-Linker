import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../data/models/audio_playback_history.dart';
import '../../data/models/playback_history.dart';
import '../../domain/services/playback_activation_guard.dart';

/// 视频播放下边栏所需的会话展示状态。
class PlaybackUiSession {
  PlaybackUiSession(this.history)
    : statusNotBefore = history.createdAt,
      lastSyncedPos = history.videoIndex;

  PlaybackHistory history;
  DateTime statusNotBefore;
  int lastSyncedPos;
  int finishPending = 0;
  bool? paused;
  bool syncBusy = false;
  bool deleting = false;
  bool launching = false;
  bool recovering = false;
  final PlaybackActivationGuard activationGuard = PlaybackActivationGuard();
  double? lastReportedPositionSeconds;
  double? lastReportedDurationSeconds;
  DateTime? lastProgressPersistedAt;

  List<String> get playlistFileNames => history.playlistFileNames.isEmpty
      ? [history.fileName]
      : history.playlistFileNames;
}

/// 音频播放下边栏所需的会话展示状态。
class AudioPlaybackUiSession {
  AudioPlaybackUiSession(this.history)
    : statusNotBefore = history.createdAt,
      lastSyncedPos = history.trackIndex;

  AudioPlaybackHistory history;
  DateTime statusNotBefore;
  int lastSyncedPos;
  int finishPending = 0;
  bool? paused;
  bool syncBusy = false;
  bool deleting = false;
  bool launching = false;
  final PlaybackActivationGuard activationGuard = PlaybackActivationGuard();
  double? lastReportedPositionSeconds;
  double? lastReportedDurationSeconds;
  DateTime? lastProgressPersistedAt;

  List<String> get playlistFileNames => history.playlistFileNames.isEmpty
      ? [history.fileName]
      : history.playlistFileNames;
}

/// 集中持有视频与音频下边栏的展示会话和轮询计时器。
///
/// MPV 同步、恢复和持久化仍由原页面流程执行，本类不改变其业务时序。
class PlaybackSessionPresenter extends ChangeNotifier {
  final List<PlaybackUiSession> _videoSessions = [];
  final List<AudioPlaybackUiSession> _audioSessions = [];
  Timer? _videoMonitor;
  Timer? _audioMonitor;
  int _videoSequence = 0;
  int _audioSequence = 0;

  List<PlaybackUiSession> get videoSessions =>
      UnmodifiableListView(_videoSessions);
  List<AudioPlaybackUiSession> get audioSessions =>
      UnmodifiableListView(_audioSessions);
  Timer? get videoMonitor => _videoMonitor;
  Timer? get audioMonitor => _audioMonitor;

  set videoMonitor(Timer? timer) {
    if (identical(timer, _videoMonitor)) return;
    _videoMonitor?.cancel();
    _videoMonitor = timer;
  }

  set audioMonitor(Timer? timer) {
    if (identical(timer, _audioMonitor)) return;
    _audioMonitor?.cancel();
    _audioMonitor = timer;
  }

  PlaybackUiSession? videoSessionById(String sessionId) {
    for (final session in _videoSessions) {
      if (session.history.sessionId == sessionId) return session;
    }
    return null;
  }

  AudioPlaybackUiSession? audioSessionById(String sessionId) {
    for (final session in _audioSessions) {
      if (session.history.sessionId == sessionId) return session;
    }
    return null;
  }

  String newVideoSessionId() =>
      'play_${DateTime.now().microsecondsSinceEpoch}_${++_videoSequence}';

  String newAudioSessionId() =>
      'audio_${DateTime.now().microsecondsSinceEpoch}_${++_audioSequence}';

  void replaceVideoSessions(Iterable<PlaybackHistory> histories) {
    _videoSessions
      ..clear()
      ..addAll(histories.map(PlaybackUiSession.new));
    notifyListeners();
  }

  void replaceAudioSessions(Iterable<AudioPlaybackHistory> histories) {
    _audioSessions
      ..clear()
      ..addAll(histories.map(AudioPlaybackUiSession.new));
    notifyListeners();
  }

  void addVideoSession(PlaybackUiSession session) {
    _videoSessions
      ..add(session)
      ..sort((a, b) => a.history.createdAt.compareTo(b.history.createdAt));
    notifyListeners();
  }

  void addAudioSession(AudioPlaybackUiSession session) {
    _audioSessions
      ..add(session)
      ..sort((a, b) => a.history.createdAt.compareTo(b.history.createdAt));
    notifyListeners();
  }

  void removeVideoSession(PlaybackUiSession session) {
    if (_videoSessions.remove(session)) notifyListeners();
  }

  void removeAudioSession(AudioPlaybackUiSession session) {
    if (_audioSessions.remove(session)) notifyListeners();
  }

  @override
  void dispose() {
    _videoMonitor?.cancel();
    _audioMonitor?.cancel();
    super.dispose();
  }
}
