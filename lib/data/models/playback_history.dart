import 'media_source.dart';

enum PlaybackHistoryKind { video, iso }

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
    this.kind = PlaybackHistoryKind.video,
    this.isoKey,
    this.isoSessionDirectoryPath,
    this.sourceId,
    this.playbackMode = PlaybackMode.legacyTitle,
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

  /// 下边栏会话类型；旧记录缺失时保持普通视频语义。
  final PlaybackHistoryKind kind;

  /// ISO 专用匿名键，用于读取 Title/MPLS 续播状态。
  final String? isoKey;

  /// 活动 ISO 会话目录；播放器退出后清空，仅用于进程同步和控制。
  final String? isoSessionDirectoryPath;

  /// 播放来源身份；旧记录为空时沿用当前 WebDAV 来源语义。
  final String? sourceId;
  final PlaybackMode playbackMode;

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
    PlaybackHistoryKind? kind,
    String? isoKey,
    String? isoSessionDirectoryPath,
    bool clearIsoSessionDirectoryPath = false,
    String? sourceId,
    PlaybackMode? playbackMode,
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
    kind: kind ?? this.kind,
    isoKey: isoKey ?? this.isoKey,
    isoSessionDirectoryPath: clearIsoSessionDirectoryPath
        ? null
        : (isoSessionDirectoryPath ?? this.isoSessionDirectoryPath),
    sourceId: sourceId ?? this.sourceId,
    playbackMode: playbackMode ?? this.playbackMode,
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
    if (kind != PlaybackHistoryKind.video) 'kind': kind.name,
    if (isoKey != null) 'isoKey': isoKey,
    if (playbackMode != PlaybackMode.legacyTitle) 'playbackMode': playbackMode.name,
    if (isoSessionDirectoryPath != null)
      'isoSessionDirectoryPath': isoSessionDirectoryPath,
    if (sourceId != null) 'sourceId': sourceId,
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
    kind:
        PlaybackHistoryKind.values
            .where((kind) => kind.name == json['kind'])
            .firstOrNull ??
        PlaybackHistoryKind.video,
    isoKey: json['isoKey'] as String?,
    isoSessionDirectoryPath: json['isoSessionDirectoryPath'] as String?,
    sourceId: json['sourceId'] as String?,
    playbackMode: PlaybackModeJson.fromJson(json['playbackMode']),
  );
}
