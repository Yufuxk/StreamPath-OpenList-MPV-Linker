import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../data/models/webdav_bdmv.dart';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../../data/local/iso_subtitle_store.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';
import '../repositories/media_directory_source.dart';
import 'iso_subtitle_scripts.dart';
import 'iso_subtitle_matcher.dart';
import 'mpv_session_controller.dart';
import 'webdav_font_matcher.dart';
import 'webdav_font_localizer.dart';
import 'webdav_media_source_adapter.dart';

class IsoSubtitleCandidate {
  const IsoSubtitleCandidate(this.path, this.entry);
  final String path;
  final MediaDirectoryEntry entry;
  String get name => p.posix.basename(path);
}

/// 单个来源、单张 ISO 的资源与用户选择，不持有播放器进度。
class IsoSubtitleContext {
  IsoSubtitleContext({
    required this.source,
    required this.iso,
    required this.isoPath,
    required this.store,
    this.cancelled,
  });

  final MediaDirectorySource source;
  final MediaDirectoryEntry iso;
  final String isoPath;
  final IsoSubtitleStore store;
  final bool Function()? cancelled;
  final List<IsoSubtitleCandidate> candidates = [];
  final List<IsoSubtitleCandidate> fonts = [];
  final List<String> issues = [];
  final Map<String, String?> bindings = {};
  final Map<String, String> suggestions = {};
  // 自动候选在播放器确认实际 MPLS 后评分，不写入持久绑定。
  final List<Map<String, dynamic>> automaticCandidates = [];
  final Map<String, List<int>> _subtitleBytes = {};
  List<Map<String, dynamic>> titleCatalog = const [];
  bool changed = false;
  bool writable = true;
  bool _discovered = false;
  MediaDirectoryEntry? _currentIso;
  String get key {
    final identity = source is WebDavMediaSourceAdapter
        ? Uri.parse(
                (source as WebDavMediaSourceAdapter).service.resolveUrl(
                  iso.entryKey,
                ),
              )
              .replace(userInfo: '', query: '', fragment: '')
              .normalizePath()
              .toString()
        : isoPath;
    return sha256
        .convert(
          utf8.encode(
            '${source.descriptor.sourceId}\n${iso is WebDavBdmv ? 'bdmv\n' : ''}$identity',
          ),
        )
        .toString();
  }

  String get revision {
    if (iso case final WebDavBdmv disc) {
      return disc.structureRevision ?? 'pending';
    }
    final file = _currentIso ?? iso;
    return file.modified == null || file.size <= 0
        ? ''
        : '${file.size}:${file.modified!.toUtc().microsecondsSinceEpoch}';
  }

  Map<String, String> get effective =>
      !writable
            ? <String, String>{}
            : {
                ...suggestions,
                for (final title in titleCatalog)
                  if (suggestionFor(title['id'] as String, titleCatalog)
                      case final String path)
                    title['id'] as String: path,
                if (!changed)
                  for (final entry in bindings.entries)
                    if (entry.value != null) entry.key: entry.value!,
              }
        ..removeWhere(
          (id, _) =>
              !changed && bindings.containsKey(id) && bindings[id] == null,
        );

  static Future<IsoSubtitleContext> create(
    MediaDirectorySource source,
    MediaDirectoryEntry iso, {
    bool Function()? cancelled,
  }) async {
    final root = await AppPaths.libraryDirectory();
    final context = IsoSubtitleContext(
      source: source,
      iso: iso,
      isoPath: iso is WebDavBdmv ? iso.rootPath : relativePath(source, iso),
      store: IsoSubtitleStore(Directory(p.join(root.path, 'iso_subtitles'))),
      cancelled: cancelled,
    );
    await context.discover();
    return context;
  }

  static String relativePath(
    MediaDirectorySource source,
    MediaDirectoryEntry entry,
  ) {
    if (entry.sourceKind != source.descriptor.kind) {
      throw const FormatException('Source mismatch');
    }
    if (source is WebDavMediaSourceAdapter) {
      final base = Uri.parse(source.service.baseUrl);
      final target = Uri.parse(source.service.resolveUrl(entry.entryKey));
      final prefix = base.pathSegments.where((s) => s.isNotEmpty).toList();
      final segments = target.pathSegments.where((s) => s.isNotEmpty).toList();
      if (base.scheme != target.scheme ||
          base.host != target.host ||
          base.port != target.port ||
          segments.length <= prefix.length ||
          List.generate(
            prefix.length,
            (i) => segments[i] == prefix[i],
          ).contains(false)) {
        throw const FormatException('Subtitle path outside source');
      }
      return _safeRelative(segments.sublist(prefix.length).join('/'));
    }
    return _safeRelative(
      entry.relativePath.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), ''),
    );
  }

  static String _safeRelative(String value) {
    if (value.isEmpty ||
        value.contains('\\') ||
        value.contains(':') ||
        value.contains('?') ||
        value.contains('#') ||
        value.startsWith('/') ||
        value.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw const FormatException('Invalid subtitle relative path');
    }
    return value;
  }

  Future<void> discover() async {
    if (_discovered) return;
    _discovered = true;
    try {
      final saved = await store.load(key, revision);
      bindings.addAll(saved.bindings);
      changed = saved.changed;
      if (changed) issues.add('changed');
    } on FormatException {
      writable = false;
      issues.add('map');
    } on FileSystemException {
      writable = false;
      issues.add('map');
    }
    if (cancelled?.call() == true) return;
    final parent = iso is WebDavBdmv
        ? (iso as WebDavBdmv).rootPath
        : p.posix.dirname(isoPath);
    final clock = Stopwatch()..start();
    Duration budget() {
      final remaining = const Duration(seconds: 10) - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Subtitle discovery deadline');
      }
      return remaining;
    }

    try {
      final siblings = await source
          .fetchDirectory(parent == '.' ? '' : parent)
          .timeout(budget());
      if (cancelled?.call() == true) return;
      final valid = _children(siblings, parent);
      _currentIso = iso is WebDavBdmv
          ? iso
          : valid.where((e) => e.path == isoPath).firstOrNull?.entry;
      if (_currentIso == null) {
        issues.add('changed');
        changed = true;
        return;
      }
      if (writable) {
        final saved = await store.load(key, revision);
        changed = saved.changed;
        if (changed && !issues.contains('changed')) issues.add('changed');
      }
      final isoCount = iso is WebDavBdmv
          ? 1
          : valid.where((e) => e.entry.isIso).length;
      candidates.addAll(
        valid.where((e) => _subtitle(e.path) && !e.entry.isDirectory),
      );
      final dirs = valid.where(
        (e) =>
            e.entry.isDirectory &&
            {
              'subtitles',
              'subtitle',
              'subs',
              'sub',
              '字幕',
            }.contains(e.entry.name.toLowerCase()),
      );
      for (final dir in dirs) {
        if (cancelled?.call() == true) return;
        try {
          await source.resolve(dir.entry);
          if (cancelled?.call() == true) return;
          final entries = await source
              .fetchDirectory(dir.path)
              .timeout(budget());
          candidates.addAll(
            _children(
              entries,
              dir.path,
            ).where((e) => !e.entry.isDirectory && _subtitle(e.path)),
          );
        } on AppException {
          issues.add('scan');
        } on TimeoutException {
          issues.add('scan');
        }
      }
      if (cancelled?.call() == true) return;
      if (iso is WebDavBdmv && parent.isNotEmpty) {
        final outer = p.posix.dirname(parent);
        final outerPath = outer == '.' ? '' : outer;
        final entries = await source
            .fetchDirectory(outerPath)
            .timeout(budget());
        final discStem = p.posix.basename(parent).toLowerCase();
        candidates.addAll(
          _children(entries, outerPath).where(
            (e) =>
                !e.entry.isDirectory &&
                _subtitle(e.path) &&
                IsoSubtitleMatcher.describe(e.path, discStem, 2) != null,
          ),
        );
      }
      candidates.sort((a, b) => a.path.compareTo(b.path));
      final stem = p.posix.basenameWithoutExtension(isoPath).toLowerCase();
      var scannedBytes = 0;
      for (final candidate in candidates.take(64)) {
        if (cancelled?.call() == true) return;
        final rule = IsoSubtitleMatcher.describe(
          candidate.path,
          stem,
          isoCount,
        );
        if (rule == null) continue;
        try {
          final bytes = await readBytes(
            candidate,
            16 * 1024 * 1024,
            budget(),
          ).timeout(budget());
          scannedBytes += bytes.length;
          if (scannedBytes > 64 * 1024 * 1024) {
            issues.add('limit');
            break;
          }
          _subtitleBytes[candidate.path] = bytes;
          rule['duration'] = IsoSubtitleMatcher.duration(bytes, candidate.path);
          automaticCandidates.add(rule);
        } on AppException {
          issues.add('download');
        } on FileSystemException {
          issues.add('download');
        } on FormatException {
          issues.add('limit');
        }
      }
      for (final rule in automaticCandidates) {
        final id = rule['mpls'] as String?;
        if (id != null) {
          suggestions[id] = IsoSubtitleMatcher.best(
            id,
            const [],
            automaticCandidates,
          )!;
        }
      }
      final fontDirs =
          valid
              .where(
                (e) =>
                    e.entry.isDirectory &&
                    WebDavFontMatcher.directoryScore(e.entry.name) != null,
              )
              .toList()
            ..sort((a, b) {
              final score = WebDavFontMatcher.directoryScore(
                b.entry.name,
              )!.compareTo(WebDavFontMatcher.directoryScore(a.entry.name)!);
              if (score != 0) return score;
              final length = a.entry.name.length.compareTo(b.entry.name.length);
              return length != 0 ? length : a.path.compareTo(b.path);
            });
      if (cancelled?.call() == true) return;
      if (fontDirs.isNotEmpty) {
        final dir = fontDirs.first;
        await source.resolve(dir.entry);
        if (cancelled?.call() == true) return;
        final entries = await source.fetchDirectory(dir.path).timeout(budget());
        fonts.addAll(
          _children(entries, dir.path).where(
            (e) =>
                !e.entry.isDirectory &&
                AppConstants.fontExtensions.contains(
                  p.posix.extension(e.path).toLowerCase(),
                ),
          ),
        );
      }
    } on FormatException {
      writable = false;
      changed = true;
      issues.add('map');
    } on AppException {
      issues.add('scan');
    } on FileSystemException {
      issues.add('scan');
    } on TimeoutException {
      issues.add('scan');
    }
  }

  List<IsoSubtitleCandidate> _children(
    List<MediaDirectoryEntry> entries,
    String parent,
  ) {
    final output = <IsoSubtitleCandidate>[];
    for (final entry in entries) {
      if (entry.isSelfEntry) continue;
      try {
        final path = relativePath(source, entry);
        if (p.posix.dirname(path) == parent) {
          output.add(IsoSubtitleCandidate(path, entry));
        }
      } on FormatException {
        /* 不接纳越界目录条目。 */
      }
    }
    return output;
  }

  static bool _subtitle(String path) =>
      {'.ass', '.ssa', '.srt'}.contains(p.posix.extension(path).toLowerCase());

  String? suggestionFor(String id, List<Map<String, dynamic>> titles) =>
      IsoSubtitleMatcher.best(id, titles, automaticCandidates);

  Future<void> bind(String id, String? path, {bool automatic = false}) async {
    if (!writable || !RegExp(r'^\d{5}$').hasMatch(id)) {
      throw const FormatException('ISO subtitle map unavailable');
    }
    if (path != null && !candidates.any((c) => c.path == path)) {
      throw const FormatException('Unknown subtitle candidate');
    }
    final next = await store.update(
      key,
      revision,
      id,
      path,
      automatic: automatic,
    );
    bindings
      ..clear()
      ..addAll(next);
    changed = false;
    issues.remove('changed');
  }

  Future<IsoSubtitleSession> prepare(
    Directory directory, {
    required String sessionId,
    required String pipeName,
    required bool menu,
    required bool autoSelect,
    List<Map<String, String>> playlist = const [],
  }) async {
    await directory.create(recursive: true);
    final session = IsoSubtitleSession(this, directory, sessionId, pipeName);
    await session.prepareBindings();
    String? fontDirectory;
    if (fonts.isNotEmpty &&
        candidates.any(
          (c) => {
            '.ass',
            '.ssa',
          }.contains(p.posix.extension(c.path).toLowerCase()),
        )) {
      final remaining = session.remaining;
      if (remaining > Duration.zero) {
        final localized =
            await WebDavFontLocalizer(preparationTimeout: remaining).localize(
              source: WebDavFontDirectory(
                name: 'fonts',
                requestPath: 'fonts',
                entryKey: 'fonts',
                files: fonts
                    .map(
                      (f) => WebDavFontFile(
                        name: f.name,
                        url: f.path,
                        size: f.entry.size,
                      ),
                    )
                    .toList(),
              ),
              base: directory,
              sessionId: sessionId,
              loader: (path, {required maxBytes, required timeout}) async {
                final candidate = fonts.firstWhere((f) => f.path == path);
                return readBytes(candidate, maxBytes, timeout);
              },
            );
        fontDirectory = localized?.directory.path;
        if (localized == null || localized.files.length != fonts.length) {
          issues.add('fonts');
        }
      } else {
        issues.add('fonts');
      }
    }
    session.scriptPath = await IsoSubtitleScripts.write(
      directory,
      sessionId: sessionId,
      menu: menu,
      autoSelect: autoSelect,
      bindings: session.localBindings,
      overrides: changed ? const [] : bindings.keys.toList(),
      titles: titleCatalog,
      candidates: automaticCandidates,
      playlist: playlist,
      fontDirectory: fontDirectory,
    );
    await File(
      p.join(directory.path, 'iso-subtitle-session.json'),
    ).writeAsString(
      jsonEncode({
        'version': 1,
        'key': key,
        'revision': revision,
        'session': sessionId,
        'pipe': pipeName,
        'bindings': session.localBindings,
      }),
      flush: true,
    );
    return session;
  }

  Future<void> refreshDiscRevision() async {
    if (iso is WebDavBdmv) {
      try {
        final saved = await store.load(key, revision);
        bindings
          ..clear()
          ..addAll(saved.bindings);
        changed = saved.changed;
        issues.remove('changed');
        if (changed) issues.add('changed');
      } on FormatException {
        writable = false;
        issues.add('map');
      } on FileSystemException {
        writable = false;
        issues.add('map');
      }
    }
  }

  Future<List<String>> prepareArgs(
    Directory directory, {
    required String sessionId,
    required String pipeName,
    required bool menu,
    required bool autoSelect,
    List<Map<String, String>> playlist = const [],
  }) async {
    try {
      final session = await prepare(
        directory,
        sessionId: sessionId,
        pipeName: pipeName,
        menu: menu,
        autoSelect: autoSelect,
        playlist: playlist,
      );
      return ['--sub-auto=no', '--script=${session.scriptPath}'];
    } on FileSystemException {
      issues.add('download');
    } on AppException {
      issues.add('download');
    }
    return [];
  }

  Future<List<int>> readBytes(
    IsoSubtitleCandidate file,
    int maxBytes,
    Duration timeout,
  ) async {
    if (_subtitleBytes[file.path] case final List<int> bytes) return bytes;
    if (file.entry.size > maxBytes) {
      throw const FormatException('Subtitle resource too large');
    }
    final target = await source.resolve(file.entry);
    if (target is WebDavMediaOpenTarget && source is WebDavMediaSourceAdapter) {
      return (source as WebDavMediaSourceAdapter).service.fetchFileBytes(
        target.url,
        maxBytes: maxBytes,
        timeout: timeout,
      );
    }
    final local = File((target as LocalMediaOpenTarget).path);
    if (await local.length() > maxBytes) {
      throw const FormatException('Subtitle resource too large');
    }
    final bytes = await local.readAsBytes();
    if (bytes.length > maxBytes) {
      throw const FormatException('Subtitle resource too large');
    }
    return bytes;
  }
}

class IsoSubtitleSession {
  IsoSubtitleSession(
    this.context,
    this.directory,
    this.sessionId,
    this.pipeName,
  );
  final IsoSubtitleContext context;
  final Directory directory;
  final String sessionId;
  final String pipeName;
  final Map<String, String> localBindings = {};
  final Map<String, String> _localized = {};
  final Stopwatch _clock = Stopwatch()..start();
  String? scriptPath;
  Duration get remaining => const Duration(seconds: 10) - _clock.elapsed;

  Future<void> prepareBindings() async {
    final next = <String, String>{};
    var bytesTotal = 0;
    // 计入本会话已有的字幕副本，手工更换绑定不能绕过总量上限。
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File &&
          RegExp(
            r'^[a-f0-9]{64}\.(ass|ssa|srt)$',
          ).hasMatch(p.basename(entry.path))) {
        bytesTotal += await entry.length();
      }
    }
    final entries = {
      ...context.effective,
      if (context.writable)
        for (final rule in context.automaticCandidates)
          'candidate:${rule['path']}': rule['path'] as String,
    }.entries.toList();
    final paths = <String>{};
    for (final entry in entries) {
      if (!paths.contains(entry.value) && paths.length >= 64) {
        context.issues.add('limit');
        continue;
      }
      paths.add(entry.value);
      final candidate = context.candidates
          .where((c) => c.path == entry.value)
          .firstOrNull;
      if (candidate == null) {
        context.issues.add('missing');
        continue;
      }
      try {
        final target = await context.source.resolve(candidate.entry);
        if (target is LocalMediaOpenTarget) {
          if (await File(target.path).length() > 16 * 1024 * 1024) {
            context.issues.add('limit');
            continue;
          }
          next[entry.key] = target.path;
          continue;
        }
        if (_localized.containsKey(candidate.path)) {
          next[entry.key] = _localized[candidate.path]!;
          continue;
        }
        if (remaining <= Duration.zero) {
          context.issues.add('timeout');
          break;
        }
        final bytes = await context
            .readBytes(candidate, 16 * 1024 * 1024, remaining)
            .timeout(remaining);
        if (bytes.isEmpty || bytes.length > 16 * 1024 * 1024) {
          context.issues.add('limit');
          continue;
        }
        final name =
            sha256.convert(bytes).toString() +
            p.posix.extension(candidate.path).toLowerCase();
        final file = File(p.join(directory.path, name));
        if (!await file.exists()) {
          if (bytesTotal + bytes.length > 64 * 1024 * 1024) {
            context.issues.add('limit');
            continue;
          }
          bytesTotal += bytes.length;
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsBytes(bytes, flush: true);
          await temporary.rename(file.path);
        }
        _localized[candidate.path] = file.path;
        next[entry.key] = file.path;
      } on AppException {
        context.issues.add('download');
      } on FileSystemException {
        context.issues.add('download');
      } on TimeoutException {
        context.issues.add('timeout');
      } on FormatException {
        context.issues.add('limit');
      }
    }
    localBindings
      ..clear()
      ..addAll(next);
  }

  Future<Map<String, dynamic>?> snapshot() async {
    final ipc = MpvSessionController(pipeName: pipeName);
    try {
      if (!await ipc.connect(timeout: const Duration(milliseconds: 500))) {
        return null;
      }
      final value = await ipc.getProperty('user-data/streampath/iso-subtitles');
      if (value is! Map || value['session'] != sessionId) return null;
      return Map<String, dynamic>.from(value);
    } finally {
      await ipc.dispose();
    }
  }

  Future<bool> update(Map<String, dynamic> snapshot) async {
    _clock
      ..reset()
      ..start();
    await prepareBindings();
    final ipc = MpvSessionController(pipeName: pipeName);
    try {
      if (!await ipc.connect(timeout: const Duration(milliseconds: 500))) {
        return false;
      }
      final current = await ipc.getProperty(
        'user-data/streampath/iso-subtitles',
      );
      if (current is! Map ||
          current['session'] != sessionId ||
          current['generation'] != snapshot['generation'] ||
          current['current'] != snapshot['current']) {
        return false;
      }
      final updateId = DateTime.now().microsecondsSinceEpoch.toString();
      await ipc.command([
        'script-message',
        'iso-subtitle-update',
        sessionId,
        jsonEncode({
          'generation': snapshot['generation'],
          'current': snapshot['current'],
          'bindings': localBindings,
          'candidates': context.automaticCandidates,
          'overrides': context.changed
              ? <String>[]
              : context.bindings.keys.toList(),
          'update': updateId,
        }),
      ]);
      final deadline = DateTime.now().add(const Duration(seconds: 1));
      while (DateTime.now().isBefore(deadline)) {
        final applied = await ipc.getProperty(
          'user-data/streampath/iso-subtitles',
        );
        if (applied is Map &&
            applied['session'] == sessionId &&
            applied['update'] == updateId) {
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return false;
    } finally {
      await ipc.dispose();
    }
  }

  static Future<IsoSubtitleSession?> restore(
    IsoSubtitleContext context,
    Directory directory,
  ) async {
    final file = File(p.join(directory.path, 'iso-subtitle-session.json'));
    if (!await file.exists()) return null;
    final data = jsonDecode(await file.readAsString());
    if (context.iso case final WebDavBdmv disc) {
      if (data is! Map ||
          data['key'] != context.key ||
          data['revision'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(data['revision'] as String)) {
        return null;
      }
      disc.structureRevision = data['revision'] as String;
      await context.refreshDiscRevision();
    }
    if (data is! Map ||
        data['version'] != 1 ||
        data['key'] != context.key ||
        data['revision'] != context.revision ||
        data['session'] is! String ||
        data['pipe'] is! String) {
      return null;
    }
    return IsoSubtitleSession(
      context,
      directory,
      data['session'],
      data['pipe'],
    );
  }
}
