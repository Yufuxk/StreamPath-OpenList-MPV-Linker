import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';
import '../../data/models/local_root_config.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';
import '../repositories/media_directory_source.dart';

typedef LocalPathCanonicalizer = Future<String> Function(String path);

/// 单个本地根目录的按需浏览与最终路径隔离实现。
class LocalMediaSource implements MediaDirectorySource {
  LocalMediaSource(
    this.root, {
    @visibleForTesting LocalPathCanonicalizer? canonicalizer,
  }) : _canonicalizer = canonicalizer ?? _resolveCanonicalPath;

  final LocalRootConfig root;
  final LocalPathCanonicalizer _canonicalizer;
  final Map<String, List<MediaDirectoryEntry>> _cache = {};
  String? _canonicalRoot;

  @override
  MediaSourceDescriptor get descriptor => MediaSourceDescriptor(
    sourceId: root.sourceId,
    kind: MediaSourceKind.local,
    displayName: root.displayName,
  );

  @override
  bool get supportsRemoteSearch => false;

  @override
  List<MediaDirectoryEntry>? cachedDirectory(String relativePath) =>
      _cache[_normalizeRelativePath(relativePath)];

  @override
  Future<List<MediaDirectoryEntry>> fetchDirectory(
    String relativePath, {
    bool forceRefresh = false,
  }) async {
    if (!root.enabled) throw AppException.config('该本地文件夹已停用');
    final normalized = _normalizeRelativePath(relativePath);
    if (!forceRefresh) {
      final cached = _cache[normalized];
      if (cached != null) return cached;
    }
    final directoryPath = await _validatedLexicalPath(
      normalized,
      expectDirectory: true,
    );
    final entries = <MediaDirectoryEntry>[];
    if (normalized.isNotEmpty) {
      entries.add(
        LocalMediaEntry(
          name: '..',
          relativePath: _parentRelativePath(normalized),
          absolutePath: p.dirname(directoryPath),
          isDirectory: true,
          isSelfEntry: true,
        ),
      );
    }
    try {
      await for (final entity in Directory(
        directoryPath,
      ).list(followLinks: false)) {
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: true,
        );
        if (type != FileSystemEntityType.directory &&
            type != FileSystemEntityType.file) {
          continue;
        }
        final stat = await entity.stat();
        final name = p.basename(entity.path);
        final childRelative = _joinRelative(normalized, name);
        entries.add(
          LocalMediaEntry(
            name: name,
            relativePath: childRelative,
            absolutePath: entity.path,
            isDirectory: type == FileSystemEntityType.directory,
            size: type == FileSystemEntityType.file ? stat.size : 0,
            modified: stat.modified,
          ),
        );
      }
    } on FileSystemException catch (error) {
      throw AppException.storage('无法读取本地目录', error);
    }
    final result = List<MediaDirectoryEntry>.unmodifiable(entries);
    _cache[normalized] = result;
    return result;
  }

  @override
  Future<MediaOpenTarget> resolve(MediaDirectoryEntry entry) async {
    if (entry is! LocalMediaEntry) {
      throw ArgumentError.value(entry, 'entry', '本地来源只能解析本地条目');
    }
    return LocalMediaOpenTarget(
      await _validatedLexicalPath(
        entry.relativePath,
        expectDirectory: entry.isDirectory,
      ),
    );
  }

  /// 解析媒体中心保存的相对路径；打开前仍执行最终路径边界校验。
  Future<String> resolveRelativePath(
    String relativePath, {
    bool expectDirectory = false,
  }) => _validatedLexicalPath(
    _normalizeRelativePath(relativePath),
    expectDirectory: expectDirectory,
  );

  /// 返回用于进度键的稳定词法路径，不执行 I/O。
  String lexicalPath(String relativePath) {
    final normalized = _normalizeRelativePath(relativePath);
    return normalized.isEmpty
        ? root.path
        : p.joinAll([root.path, ...normalized.split('/')]);
  }

  /// 把已校验的蓝光设备路径还原为媒体库使用的相对路径。
  String discRelativePath(String devicePath) {
    final relative = p.relative(devicePath, from: root.path);
    return relative == '.' ? '' : _normalizeRelativePath(relative);
  }

  /// 校验 ISO 或 BDMV 结构并返回 MPV 的 --bluray-device 路径。
  Future<String> resolveDiscDevice(String relativePath) async {
    try {
      return await _resolveDiscDevice(relativePath);
    } on FileSystemException catch (error) {
      throw AppException.storage('本地蓝光路径不存在或不可访问', error);
    }
  }

  Future<String> _resolveDiscDevice(String relativePath) async {
    final normalized = _normalizeRelativePath(relativePath);
    final target = await _validatedLexicalPath(normalized);
    final type = await FileSystemEntity.type(target, followLinks: true);
    if (type == FileSystemEntityType.file &&
        p.extension(target).toLowerCase() == '.iso') {
      return target;
    }
    if (type != FileSystemEntityType.directory) {
      throw AppException.config('请选择 Blu-ray ISO 或有效的 BDMV 文件夹');
    }
    final discRoot = p.basename(target).toLowerCase() == 'bdmv'
        ? p.dirname(target)
        : target;
    await _validatedAbsolutePath(discRoot);
    final bdmvPath = await _validatedAbsolutePath(p.join(discRoot, 'BDMV'));
    final required = <FileSystemEntity>[
      File(p.join(bdmvPath, 'index.bdmv')),
      Directory(p.join(bdmvPath, 'PLAYLIST')),
      Directory(p.join(bdmvPath, 'STREAM')),
    ];
    for (final entity in required) {
      if (!await entity.exists()) {
        throw AppException.config('所选目录不是有效的 Blu-ray BDMV 根目录');
      }
    }
    return discRoot;
  }

  Future<bool> hasDiscAt(String relativePath) async {
    try {
      await resolveDiscDevice(relativePath);
      return true;
    } on AppException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  Future<String> _validatedLexicalPath(
    String relativePath, {
    bool? expectDirectory,
  }) async {
    final normalized = _normalizeRelativePath(relativePath);
    final lexical = lexicalPath(normalized);
    try {
      await _validatedAbsolutePath(lexical);
      if (expectDirectory != null) {
        final type = await FileSystemEntity.type(lexical, followLinks: true);
        if (expectDirectory && type != FileSystemEntityType.directory) {
          throw AppException.storage('本地目录不存在或不可访问');
        }
        if (!expectDirectory && type != FileSystemEntityType.file) {
          throw AppException.storage('本地文件不存在或不可访问');
        }
      }
    } on FileSystemException catch (error) {
      throw AppException.storage(
        expectDirectory == true ? '本地目录不存在或不可访问' : '本地文件不存在或不可访问',
        error,
      );
    }
    return lexical;
  }

  Future<String> _validatedAbsolutePath(String path) async {
    final canonicalRoot = await _loadCanonicalRoot();
    final canonicalTarget = p.normalize(await _canonicalizer(path));
    if (!_sameOrWithin(canonicalRoot, canonicalTarget)) {
      throw AppException.storage('已拒绝指向本地根目录外的路径');
    }
    return path;
  }

  Future<String> _loadCanonicalRoot() async {
    final cached = _canonicalRoot;
    if (cached != null) return cached;
    try {
      final canonical = p.normalize(await _canonicalizer(root.path));
      _canonicalRoot = canonical;
      return canonical;
    } on FileSystemException catch (error) {
      throw AppException.storage('本地根目录不存在或不可访问', error);
    }
  }

  static Future<String> _resolveCanonicalPath(String path) =>
      File(path).resolveSymbolicLinks();

  static String _normalizeRelativePath(String value) {
    final raw = value.trim().replaceAll('\\', '/');
    if (raw.isEmpty) return '';
    if (raw.startsWith('/') || p.isAbsolute(raw)) {
      throw const FormatException('本地目录路径必须是根目录内的相对路径');
    }
    final segments = raw.split('/');
    if (segments.any(
      (segment) =>
          segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          segment.trim().isEmpty,
    )) {
      throw const FormatException('本地目录路径不能包含空段、. 或 ..');
    }
    return segments.join('/');
  }

  static String _joinRelative(String parent, String name) =>
      parent.isEmpty ? name : '$parent/$name';

  static String _parentRelativePath(String value) {
    final segments = value.split('/');
    return segments.length <= 1
        ? ''
        : segments.sublist(0, segments.length - 1).join('/');
  }

  static bool _sameOrWithin(String root, String target) {
    final normalizedRoot = Platform.isWindows ? root.toLowerCase() : root;
    final normalizedTarget = Platform.isWindows ? target.toLowerCase() : target;
    return normalizedTarget == normalizedRoot ||
        p.isWithin(normalizedRoot, normalizedTarget);
  }
}
