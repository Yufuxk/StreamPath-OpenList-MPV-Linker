import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../../data/models/film_catalog_item.dart';

typedef _NewNative = Pointer<Void> Function();
typedef _DeleteNative = Void Function(Pointer<Void>);
typedef _OptionNative =
    Pointer<Utf16> Function(Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>);
typedef _InitNative = UintPtr Function(Pointer<Void>, Uint64, Uint64);
typedef _ContinueNative =
    UintPtr Function(Pointer<Void>, Pointer<Uint8>, UintPtr);
typedef _GoToNative = Uint64 Function(Pointer<Void>);
typedef _FinalizeNative = UintPtr Function(Pointer<Void>);
typedef _InformNative = Pointer<Utf16> Function(Pointer<Void>, UintPtr);

/// 仅接收宿主提供的块，MediaInfo 不自行打开文件或网络。
class MediaInfoBuffer {
  MediaInfoBuffer(String libraryPath)
    : _library = DynamicLibrary.open(libraryPath) {
    _handle = _library.lookupFunction<_NewNative, Pointer<Void> Function()>(
      'MediaInfo_New',
    )();
    _option('Inform', 'JSON');
    _option('ParseSpeed', '0');
    _option('Complete', '1');
  }
  final DynamicLibrary _library;
  late final Pointer<Void> _handle;
  void _option(String key, String value) {
    final k = key.toNativeUtf16(), v = value.toNativeUtf16();
    try {
      _library.lookupFunction<
        _OptionNative,
        Pointer<Utf16> Function(Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>)
      >('MediaInfo_Option')(_handle, k, v);
    } finally {
      calloc.free(k);
      calloc.free(v);
    }
  }

  void initialize(int size, int offset) => _library
      .lookupFunction<_InitNative, int Function(Pointer<Void>, int, int)>(
        'MediaInfo_Open_Buffer_Init',
      )(_handle, size, offset);
  int feed(Uint8List bytes) {
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      return _library.lookupFunction<
        _ContinueNative,
        int Function(Pointer<Void>, Pointer<Uint8>, int)
      >('MediaInfo_Open_Buffer_Continue')(_handle, buffer, bytes.length);
    } finally {
      calloc.free(buffer);
    }
  }

  int get seek =>
      _library.lookupFunction<_GoToNative, int Function(Pointer<Void>)>(
        'MediaInfo_Open_Buffer_Continue_GoTo_Get',
      )(_handle);
  Map<String, dynamic> finish() {
    _library.lookupFunction<_FinalizeNative, int Function(Pointer<Void>)>(
      'MediaInfo_Open_Buffer_Finalize',
    )(_handle);
    final json = _library
        .lookupFunction<
          _InformNative,
          Pointer<Utf16> Function(Pointer<Void>, int)
        >('MediaInfo_Inform')(_handle, 0)
        .toDartString();
    return Map<String, dynamic>.from(jsonDecode(json));
  }

  void close() =>
      _library.lookupFunction<_DeleteNative, void Function(Pointer<Void>)>(
        'MediaInfo_Delete',
      )(_handle);
}

/// 可取消的独立解析 isolate；每次最多一个媒体文件。
class MediaInfoProbe {
  MediaInfoProbe({
    String? libraryPath,
    this.maxBytes = 8 * 1024 * 1024,
    this.maxRequests = 32,
    this.remoteInterval = const Duration(seconds: 1),
    this.timeout = const Duration(seconds: 45),
  }) : libraryPath =
           libraryPath ??
           p.join(p.dirname(Platform.resolvedExecutable), 'MediaInfo.dll');
  final String libraryPath;
  final int maxBytes, maxRequests;
  final Duration remoteInterval, timeout;
  SendPort? _commands;
  Future<Map<String, dynamic>>? _running;
  bool _cancelled = false;
  Future<Map<String, dynamic>> probe(
    String target, {
    Map<String, String> headers = const {},
  }) {
    if (_running != null) throw StateError('Media probe is already running');
    _cancelled = false;
    final task = _start(target, headers);
    _running = task;
    return task.whenComplete(() {
      _running = null;
      _commands = null;
    });
  }

  Future<void> cancel() async {
    _cancelled = true;
    _commands?.send('cancel');
    try {
      await _running;
    } on FilmCatalogException {
      /* 取消由调用方显示状态。 */
    }
  }

  Future<Map<String, dynamic>> _start(
    String target,
    Map<String, String> headers,
  ) async {
    final replies = ReceivePort();
    final completer = Completer<Map<String, dynamic>>();
    final errors = ReceivePort();
    final subscription = replies.listen((message) {
      if (message is SendPort) {
        _commands = message;
        if (_cancelled) message.send('cancel');
      } else if (message is Map && !completer.isCompleted) {
        if (message['error'] != null) {
          completer.completeError(
            FilmCatalogException(message['error'] as String),
          );
        } else {
          completer.complete(Map<String, dynamic>.from(message));
        }
      }
    });
    final errorSubscription = errors.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(const FilmCatalogException('probeFailed'));
      }
    });
    try {
      await Isolate.spawn(_probeWorker, {
        'reply': replies.sendPort,
        'library': libraryPath,
        'target': target,
        'headers': headers,
        'maxBytes': maxBytes,
        'maxRequests': maxRequests,
        'intervalMs': remoteInterval.inMilliseconds,
        'timeoutMs': timeout.inMilliseconds,
      }, onError: errors.sendPort);
      return await completer.future;
    } finally {
      await subscription.cancel();
      await errorSubscription.cancel();
      replies.close();
      errors.close();
    }
  }
}

void _probeWorker(Map<String, dynamic> args) async {
  final reply = args['reply'] as SendPort;
  final commands = ReceivePort();
  final client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 5);
  bool cancelled = false;
  bool expired = false;
  final stop = Completer<void>();
  commands.listen((_) {
    cancelled = true;
    if (!stop.isCompleted) stop.complete();
    client.close(force: true);
  });
  final timer = Timer(Duration(milliseconds: args['timeoutMs'] as int), () {
    expired = true;
    if (!stop.isCompleted) stop.complete();
    client.close(force: true);
  });
  reply.send(commands.sendPort);
  MediaInfoBuffer? parser;
  RandomAccessFile? file;
  final deadline = DateTime.now().add(
    Duration(milliseconds: args['timeoutMs'] as int),
  );
  int total = 0, requests = 0, offset = 0, size = -1;
  bool complete = false;
  String? validator;
  final target = args['target'] as String;
  final remote = target.startsWith('http://') || target.startsWith('https://');
  try {
    parser = MediaInfoBuffer(args['library'] as String);
    if (!remote) {
      file = await File(target).open();
      size = await file.length();
    }
    while (total < (args['maxBytes'] as int) &&
        requests < (args['maxRequests'] as int) &&
        DateTime.now().isBefore(deadline)) {
      if (cancelled) throw const FilmCatalogException('cancelled');
      if (remote && requests > 0) {
        await Future.any([
          Future<void>.delayed(
            Duration(milliseconds: args['intervalMs'] as int),
          ),
          stop.future,
        ]);
      }
      if (cancelled) throw const FilmCatalogException('cancelled');
      if (expired) throw const FilmCatalogException('probeTimeout');
      final length = (256 * 1024).clamp(0, (args['maxBytes'] as int) - total);
      Uint8List bytes;
      requests++;
      if (remote) {
        final request = await client
            .getUrl(Uri.parse(target))
            .timeout(const Duration(seconds: 5));
        request.followRedirects = false;
        (args['headers'] as Map).forEach(
          (key, value) => request.headers.set(key as String, value),
        );
        request.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$offset-${offset + length - 1}',
        );
        if (validator != null) {
          request.headers.set(HttpHeaders.ifRangeHeader, validator);
        }
        final response = await request.close().timeout(
          const Duration(seconds: 5),
        );
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
          response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
        );
        if (response.statusCode != 206 ||
            range == null ||
            int.parse(range[1]!) != offset ||
            int.parse(range[2]!) < offset ||
            int.parse(range[2]!) >= int.parse(range[3]!) ||
            int.parse(range[2]!) - offset + 1 > length) {
          throw const FilmCatalogException('probeRangeUnsupported');
        }
        final responseSize = int.parse(range[3]!);
        final currentValidator =
            response.headers.value(HttpHeaders.etagHeader) ??
            response.headers.value(HttpHeaders.lastModifiedHeader);
        if (validator != null && currentValidator != validator) {
          throw const FilmCatalogException('probeSourceChanged');
        }
        validator = currentValidator;
        if (size >= 0 && size != responseSize) {
          throw const FilmCatalogException('probeSourceChanged');
        }
        size = responseSize;
        final body = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(
          const Duration(seconds: 5),
        )) {
          if (cancelled) throw const FilmCatalogException('cancelled');
          if (body.length + chunk.length > length) {
            throw const FilmCatalogException('probeRangeUnsupported');
          }
          body.add(chunk);
        }
        bytes = body.takeBytes();
        if (bytes.length != int.parse(range[2]!) - offset + 1) {
          throw const FilmCatalogException('probeFailed');
        }
      } else {
        await file!.setPosition(offset);
        bytes = await file.read(length);
      }
      if (bytes.isEmpty) break;
      if (total == 0) parser.initialize(size, offset);
      total += bytes.length;
      final status = parser.feed(bytes);
      if ((status & 8) != 0) {
        complete = true;
        break;
      }
      final seek = parser.seek;
      final next = seek < 0 ? offset + bytes.length : seek;
      if (next >= size) {
        complete = true;
        break;
      }
      if (seek >= 0 && next != offset + bytes.length) {
        parser.initialize(size, next);
      }
      offset = next;
    }
    if (cancelled) throw const FilmCatalogException('cancelled');
    if (expired) throw const FilmCatalogException('probeTimeout');
    reply.send({
      ...technicalInfoFromMediaInfo(parser.finish()),
      'state': complete ? 'complete' : 'partial',
      'readBytes': total,
      'requests': requests,
      'fileSize': size,
      'origin': 'MediaInfo',
    });
  } on FilmCatalogException catch (e) {
    reply.send({'error': e.code});
  } on FileSystemException {
    reply.send({'error': 'probeFailed'});
  } on SocketException {
    reply.send({
      'error': cancelled
          ? 'cancelled'
          : expired
          ? 'probeTimeout'
          : 'probeFailed',
    });
  } on HttpException {
    reply.send({
      'error': cancelled
          ? 'cancelled'
          : expired
          ? 'probeTimeout'
          : 'probeFailed',
    });
  } on TimeoutException {
    reply.send({'error': 'probeTimeout'});
  } on FormatException {
    reply.send({'error': 'probeFailed'});
  } on ArgumentError {
    reply.send({'error': 'probeUnavailable'});
  } finally {
    timer.cancel();
    parser?.close();
    await file?.close();
    client.close(force: true);
    commands.close();
  }
}

num? _number(Object? value) => value is num
    ? value
    : value is String
    ? num.tryParse(value)
    : null;

Map<String, dynamic> technicalInfoFromMediaInfo(Map<String, dynamic> json) {
  final tracks = (json['media']?['track'] as List? ?? [])
      .whereType<Map>()
      .toList();
  final general = tracks.where((t) => t['@type'] == 'General').firstOrNull;
  return {
    'duration': _number(general?['Duration']),
    'bitrate': _number(general?['OverallBitRate']),
    'video': [
      for (final t in tracks.where((t) => t['@type'] == 'Video'))
        {
          'codec': t['Format'],
          'width': _number(t['Width']),
          'height': _number(t['Height']),
          'bitrate': _number(t['BitRate']),
          'frameRate': _number(t['FrameRate']),
          'bitDepth': _number(t['BitDepth']),
          'hdr': t['HDR_Format'],
          'hdrProfile': t['HDR_Format_Profile'],
          'transfer': t['transfer_characteristics'],
          'colorPrimaries': t['colour_primaries'],
        },
    ],
    'audio': [
      for (final t in tracks.where((t) => t['@type'] == 'Audio'))
        {
          'codec': t['Format'],
          'profile': t['Format_AdditionalFeatures'],
          'channels': _number(t['Channels']),
          'sampleRate': _number(t['SamplingRate']),
          'bitDepth': _number(t['BitDepth']),
          'bitrate': _number(t['BitRate']),
          'language': t['Language'],
          'title': t['Title'],
        },
    ],
  };
}

Map<String, dynamic> technicalInfoFromMpv(Map<String, dynamic> json) {
  final params = json['video'] as Map? ?? const {};
  final tracks = (json['tracks'] as List? ?? []).whereType<Map>();
  final video = tracks
      .where(
        (t) =>
            t['type'] == 'video' &&
            t['external'] != true &&
            t['albumart'] != true,
      )
      .firstOrNull;
  final transfer = params['gamma'];
  final dolbyVision = _number(video?['dolby-vision-profile']);
  final staticHdr = _number(params['max-luma']);
  final dynamicHdr = _number(params['scene-max-r']);
  final hdr = dolbyVision != null && dolbyVision > 0
      ? 'Dolby Vision'
      : transfer == 'pq'
      ? dynamicHdr != null && dynamicHdr > 0
            ? 'HDR10+'
            : staticHdr != null && staticHdr > 0
            ? 'HDR10'
            : 'HDR (PQ)'
      : transfer == 'hlg'
      ? 'HLG'
      : null;
  return {
    'origin': 'MPV',
    'state': 'playback',
    'fileSize': json['size'],
    'duration': json['duration'],
    'video': [
      if (video != null)
        {
          'codec': video['codec'],
          'width': video['demux-w'] ?? params['w'],
          'height': video['demux-h'] ?? params['h'],
          'bitrate': video['demux-bitrate'],
          'frameRate': video['demux-fps'],
          'bitDepth': params['component-bits'],
          'hdr': hdr,
          'hdrProfile': video['dolby-vision-profile'],
          'transfer': transfer,
          'colorPrimaries': params['primaries'],
        },
    ],
    'audio': [
      for (final t in tracks.where(
        (t) => t['type'] == 'audio' && t['external'] != true,
      ))
        {
          'codec': t['codec'],
          'channels': t['demux-channel-count'],
          'sampleRate': t['demux-samplerate'],
          'bitrate': t['demux-bitrate'],
          'language': t['lang'],
          'title': t['title'],
        },
    ],
  };
}
