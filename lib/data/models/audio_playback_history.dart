/// 音频播放会话历史，独立于视频历史持久化。
class AudioPlaybackHistory {
  const AudioPlaybackHistory({
    required this.sessionId,
    required this.dirCrumbs,
    required this.fileName,
    required this.trackIndex,
    required this.updatedAt,
    DateTime? createdAt,
    this.playlistFileNames = const [],
    this.playerPid,
    this.ipcPipeName,
  }) : createdAt = createdAt ?? updatedAt;

  final String sessionId;
  final List<String> dirCrumbs;
  final String fileName;
  final int trackIndex;
  final DateTime updatedAt;
  final DateTime createdAt;
  final List<String> playlistFileNames;
  final int? playerPid;
  final String? ipcPipeName;

  AudioPlaybackHistory copyWith({
    String? sessionId,
    List<String>? dirCrumbs,
    String? fileName,
    int? trackIndex,
    DateTime? updatedAt,
    DateTime? createdAt,
    List<String>? playlistFileNames,
    int? playerPid,
    bool clearPlayerPid = false,
    String? ipcPipeName,
    bool clearIpcPipeName = false,
  }) => AudioPlaybackHistory(
    sessionId: sessionId ?? this.sessionId,
    dirCrumbs: dirCrumbs ?? this.dirCrumbs,
    fileName: fileName ?? this.fileName,
    trackIndex: trackIndex ?? this.trackIndex,
    updatedAt: updatedAt ?? this.updatedAt,
    createdAt: createdAt ?? this.createdAt,
    playlistFileNames: playlistFileNames ?? this.playlistFileNames,
    playerPid: clearPlayerPid ? null : (playerPid ?? this.playerPid),
    ipcPipeName: clearIpcPipeName ? null : (ipcPipeName ?? this.ipcPipeName),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'dirCrumbs': dirCrumbs,
    'fileName': fileName,
    'trackIndex': trackIndex,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'playlistFileNames': playlistFileNames,
    'playerPid': playerPid,
    'ipcPipeName': ipcPipeName,
  };

  factory AudioPlaybackHistory.fromJson(
    Map<String, dynamic> json,
  ) => AudioPlaybackHistory(
    sessionId: (json['sessionId'] as String?) ?? 'audio_legacy',
    dirCrumbs:
        (json['dirCrumbs'] as List?)?.whereType<String>().toList() ?? const [],
    fileName: (json['fileName'] as String?) ?? '',
    trackIndex: (json['trackIndex'] as num?)?.toInt() ?? 0,
    updatedAt: json['updatedAt'] == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int),
    createdAt: json['createdAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
    playlistFileNames:
        (json['playlistFileNames'] as List?)?.whereType<String>().toList() ??
        const [],
    playerPid: (json['playerPid'] as num?)?.toInt(),
    ipcPipeName: json['ipcPipeName'] as String?,
  );
}
