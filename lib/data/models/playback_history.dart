/// 上次播放记录（跨会话持久化，供「继续播放」入口使用）。
class PlaybackHistory {
  const PlaybackHistory({
    required this.dirCrumbs,
    required this.fileName,
    required this.videoIndex,
    required this.updatedAt,
    this.sessionId = 'legacy',
    DateTime? createdAt,
    this.playlistFileNames = const [],
    this.playerPid,
    this.playerExecutablePath,
    this.playerCreationTime,
    this.ipcPipeName,
    this.launchEpoch,
  }) : createdAt = createdAt ?? updatedAt;

  /// 稳定播放会话 ID；同一条下边栏续播时保持不变。
  final String sessionId;

  /// 上次播放视频所在目录的面包屑路径（如 `['动漫', '2024秋']`）。
  final List<String> dirCrumbs;

  /// 上次播放的视频文件名（显示用）。
  final String fileName;

  /// 视频在所在目录视频列表中的索引（0-based，恢复播放列表起点）。
  final int videoIndex;

  /// 记录时间。
  final DateTime updatedAt;

  /// 下边栏创建时间（决定垂直顺序；不会随切集改变）。
  final DateTime createdAt;

  /// 本会话播放列表文件名（与 mpv playlist-pos 一一对应）。
  final List<String> playlistFileNames;

  /// 对应外部播放器 PID；应用重启后用于恢复存活检测和定向关闭。
  final int? playerPid;

  /// 启动时读取的播放器规范化绝对路径，用于拒绝 PID 复用。
  final String? playerExecutablePath;

  /// 启动时读取的 Windows FILETIME 原始创建时间。
  final int? playerCreationTime;

  /// 对应 MPV IPC named pipe；应用重启后可重新建立定向控制。
  final String? ipcPipeName;

  /// 当前播放进程对应的磁盘工件代次。
  final String? launchEpoch;

  PlaybackHistory copyWith({
    String? sessionId,
    List<String>? dirCrumbs,
    String? fileName,
    int? videoIndex,
    DateTime? updatedAt,
    DateTime? createdAt,
    List<String>? playlistFileNames,
    int? playerPid,
    bool clearPlayerPid = false,
    String? playerExecutablePath,
    bool clearPlayerExecutablePath = false,
    int? playerCreationTime,
    bool clearPlayerCreationTime = false,
    String? ipcPipeName,
    bool clearIpcPipeName = false,
    String? launchEpoch,
    bool clearLaunchEpoch = false,
  }) => PlaybackHistory(
    sessionId: sessionId ?? this.sessionId,
    dirCrumbs: dirCrumbs ?? this.dirCrumbs,
    fileName: fileName ?? this.fileName,
    videoIndex: videoIndex ?? this.videoIndex,
    updatedAt: updatedAt ?? this.updatedAt,
    createdAt: createdAt ?? this.createdAt,
    playlistFileNames: playlistFileNames ?? this.playlistFileNames,
    playerPid: clearPlayerPid ? null : (playerPid ?? this.playerPid),
    playerExecutablePath: clearPlayerPid || clearPlayerExecutablePath
        ? null
        : (playerExecutablePath ?? this.playerExecutablePath),
    playerCreationTime: clearPlayerPid || clearPlayerCreationTime
        ? null
        : (playerCreationTime ?? this.playerCreationTime),
    ipcPipeName: clearIpcPipeName ? null : (ipcPipeName ?? this.ipcPipeName),
    launchEpoch: clearLaunchEpoch ? null : (launchEpoch ?? this.launchEpoch),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'dirCrumbs': dirCrumbs,
    'fileName': fileName,
    'videoIndex': videoIndex,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'playlistFileNames': playlistFileNames,
    'playerPid': playerPid,
    'playerExecutablePath': playerExecutablePath,
    'playerCreationTime': playerCreationTime,
    'ipcPipeName': ipcPipeName,
    'launchEpoch': launchEpoch,
  };

  factory PlaybackHistory.fromJson(
    Map<String, dynamic> json,
  ) => PlaybackHistory(
    sessionId: (json['sessionId'] as String?) ?? 'legacy',
    dirCrumbs:
        (json['dirCrumbs'] as List?)?.whereType<String>().toList() ?? const [],
    fileName: (json['fileName'] as String?) ?? '',
    videoIndex: (json['videoIndex'] as num?)?.toInt() ?? 0,
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
    playerExecutablePath: json['playerExecutablePath'] as String?,
    playerCreationTime: (json['playerCreationTime'] as num?)?.toInt(),
    ipcPipeName: json['ipcPipeName'] as String?,
    launchEpoch: json['launchEpoch'] as String?,
  );
}
