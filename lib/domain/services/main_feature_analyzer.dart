class MainFeatureCandidate {
  const MainFeatureCandidate({
    required this.playlist,
    required this.duration,
    required this.chapters,
    required this.clips,
    required this.video,
    required this.alternate,
    this.possibleEpisodes = false,
    this.titleIndex = 0,
  });

  final int playlist;
  final Duration duration;
  final int chapters;
  final int clips;
  final bool video;
  final bool alternate;
  final bool possibleEpisodes;
  final int titleIndex;

  String get programmeId => playlist.toString().padLeft(5, '0');

  static MainFeatureCandidate? fromMessage(Object? message) {
    if (message is! Map<String, dynamic>) return null;
    final playlist = message['playlist'];
    final duration = message['durationMs'];
    final chapters = message['chapters'];
    final clips = message['clips'];
    final video = message['video'];
    final alternate = message['alternate'];
    final titleIndex = message['titleIndex'];
    final possibleEpisodes = message['possibleEpisodes'];
    if (playlist is! int ||
        playlist < 0 ||
        playlist > 99999 ||
        duration is! int ||
        duration <= 0 ||
        chapters is! int ||
        chapters < 0 ||
        clips is! int ||
        clips <= 0 ||
        video is! bool ||
        alternate is! bool ||
        possibleEpisodes is! bool ||
        titleIndex is! int ||
        titleIndex < 0) {
      return null;
    }
    return MainFeatureCandidate(
      playlist: playlist,
      duration: Duration(milliseconds: duration),
      chapters: chapters,
      clips: clips,
      video: video,
      alternate: alternate,
      titleIndex: titleIndex,
      possibleEpisodes: possibleEpisodes,
    );
  }

  Map<String, Object> toJson() => {
    'playlist': playlist,
    'durationMs': duration.inMilliseconds,
    'chapters': chapters,
    'clips': clips,
    'video': video,
    'alternate': alternate,
    'titleIndex': titleIndex,
    'possibleEpisodes': possibleEpisodes,
  };

  static List<MainFeatureCandidate>? parseInventory(Object? raw) {
    if (raw is! List || raw.length > 256) return null;
    final candidates = <MainFeatureCandidate>[];
    final ids = <int>{};
    for (final item in raw) {
      final candidate = fromMessage(item);
      if (candidate == null || !ids.add(candidate.playlist)) return null;
      candidates.add(candidate);
    }
    return List.unmodifiable(candidates);
  }
}

typedef ConfirmedMainFeature = ({
  String revision,
  MainFeatureCandidate title,
  List<MainFeatureCandidate> candidates,
});

enum MainFeatureStatus { confirmed, highConfidence, ambiguous, unsupported }

class MainFeatureAnalysis {
  const MainFeatureAnalysis(this.status, this.reason, [this.playlist]);

  final MainFeatureStatus status;
  final String reason;
  final int? playlist;
}

class MainFeatureAnalyzer {
  static MainFeatureAnalysis analyze(
    List<MainFeatureCandidate> candidates, {
    required bool navigationAmbiguous,
    bool knownSeries = false,
    int? confirmedPlaylist,
  }) {
    if (candidates.isEmpty) {
      return const MainFeatureAnalysis(
        MainFeatureStatus.unsupported,
        'candidate_inventory_unavailable',
      );
    }
    if (candidates.any(
      (candidate) => candidate.playlist == confirmedPlaylist,
    )) {
      return MainFeatureAnalysis(
        MainFeatureStatus.confirmed,
        'verified_user_confirmation',
        confirmedPlaylist,
      );
    }
    if (navigationAmbiguous) {
      return const MainFeatureAnalysis(
        MainFeatureStatus.ambiguous,
        'navigation_not_verified',
      );
    }
    if (knownSeries ||
        candidates.any((candidate) => candidate.possibleEpisodes)) {
      return const MainFeatureAnalysis(
        MainFeatureStatus.ambiguous,
        'possible_episodic_disc',
      );
    }
    final long = candidates
        .where((candidate) => candidate.duration >= const Duration(minutes: 10))
        .toList();
    if (long.length > 1) {
      final repeatedDuration =
          long.map((candidate) => candidate.duration).toSet().length <
          long.length;
      return MainFeatureAnalysis(
        MainFeatureStatus.ambiguous,
        repeatedDuration ? 'equal_duration_variants' : 'multiple_programmes',
      );
    }
    if (long.length == 1) {
      final candidate = long.single;
      final remainder = candidates
          .where((item) => item != candidate)
          .fold(Duration.zero, (total, item) => total + item.duration);
      // 只有一项有正片结构，且其余标题合计不足以构成另一节目。
      if (candidate.duration >= const Duration(minutes: 30) &&
          candidate.chapters > 1 &&
          candidate.video &&
          !candidate.alternate &&
          remainder < const Duration(minutes: 5)) {
        return MainFeatureAnalysis(
          MainFeatureStatus.highConfidence,
          'single_feature_structure',
          candidate.playlist,
        );
      }
    }
    return const MainFeatureAnalysis(
      MainFeatureStatus.ambiguous,
      'insufficient_feature_evidence',
    );
  }
}

typedef MainFeatureProbe =
    Future<int?> Function(
      List<MainFeatureCandidate> candidates,
      String? revision,
      bool navigationAmbiguous,
    );

class MainFeatureChoice {
  const MainFeatureChoice(this.playlist);
  const MainFeatureChoice.full() : playlist = null;

  final int? playlist;
}

typedef MainFeatureSelector =
    Future<MainFeatureChoice?> Function(List<MainFeatureCandidate> candidates);
