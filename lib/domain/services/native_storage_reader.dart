import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import '../../data/models/film_catalog_item.dart';
import '../../data/models/media_connection.dart';
import '../../data/models/media_source.dart';

typedef _ConnectNative =
    Pointer<Void> Function(
      Int32,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Int32,
      Int32,
      Int32,
      Int32,
    );
typedef _Connect =
    Pointer<Void> Function(
      int,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      int,
      int,
      int,
    );
typedef _TextNative = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _Text = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _ReadNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Uint64,
      Pointer<Uint8>,
      Uint32,
    );
typedef _Read =
    int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Uint8>, int);
typedef _WriteNative =
    Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Uint32);
typedef _Write =
    int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, int);

String nativeStorageError(int code) => switch (code) {
  -2 => 'sourceFileMissing',
  -3 => 'sourceReadOnly',
  -4 => 'sourceRangeUnsupported',
  -7 => 'invalidPath',
  -8 => 'cancelled',
  -9 => 'sourceListingUnsupported',
  -10 => 'sourceConnectionFailed',
  -11 => 'sourceCreateUnsupported',
  _ => 'sourceReadFailed',
};

/// 一个原生上下文由一个工作 isolate 持有，主 isolate 只传递任务与取消信号。
abstract interface class StorageFileReader {
  Future<List<Map<String, dynamic>>> list(String path);
  Future<Map<String, dynamic>> stat(String path);
  Future<Uint8List> read(String path, int offset, int count);
  Future<void> createFile(String path, Uint8List bytes);
  void cancelCurrent();
  Future<void> close();
}

class NativeStorageReader implements StorageFileReader {
  NativeStorageReader._(
    this._isolate,
    this._commands,
    this._responses,
    this._subscription,
    this._pending,
    this._library,
    this._address,
    this._workerExit,
  );
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;
  final StreamSubscription<dynamic> _subscription;
  final Map<int, Completer<Object?>> _pending;
  final DynamicLibrary _library;
  final int _address;
  final Completer<void> _workerExit;
  Future<void>? _closeTask;
  int _sequence = 0;
  bool _closed = false;
  bool _closing = false;
  Future<void> _tail = Future.value();
  static Future<NativeStorageReader> open(
    MediaConnection config,
    String password, {
    String? libraryPath,
  }) async {
    config.validate();
    if (!config.kind.isNativeStorage) {
      throw ArgumentError('Expected native storage protocol');
    }
    final libraryFile =
        libraryPath ??
        p.join(
          p.dirname(Platform.resolvedExecutable),
          'streampath_storage.dll',
        );
    if (!File(libraryFile).existsSync()) {
      throw const FilmCatalogException('sourceNativeUnavailable');
    }
    late DynamicLibrary library;
    try {
      for (final dependency in ['smb2.dll', 'libnfs.dll', 'libcurl.dll']) {
        DynamicLibrary.open(p.join(p.dirname(libraryFile), dependency));
      }
      library = DynamicLibrary.open(libraryFile);
    } on ArgumentError {
      throw const FilmCatalogException('sourceNativeUnavailable');
    }
    final responses = ReceivePort();
    final ready = Completer<SendPort>();
    final connected = Completer<int>();
    final pending = <int, Completer<Object?>>{};
    final workerExit = Completer<void>();
    final subscription = responses.listen((message) {
      if (message == null || message is List && message.length == 2) {
        if (!workerExit.isCompleted) workerExit.complete();
        final error = message == null
            ? const FilmCatalogException('sourceConnectionFailed')
            : StateError('Native storage worker failed');
        if (!ready.isCompleted) ready.completeError(error);
        if (!connected.isCompleted) connected.completeError(error);
        for (final task in pending.values) {
          task.completeError(error);
        }
        pending.clear();
        return;
      }
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      final row = message as List;
      final id = row[0] as int;
      if (id == 0) {
        if (row[1] == true) {
          connected.complete(row[2] as int);
        } else {
          connected.completeError(FilmCatalogException(row[2] as String));
        }
        return;
      }
      final completer = pending.remove(id);
      if (row[1] == true) {
        completer?.complete(row[2]);
      } else {
        completer?.completeError(FilmCatalogException(row[2] as String));
      }
    });
    final startup = Future.wait<Object>([ready.future, connected.future]);
    final isolate = await Isolate.spawn(
      _worker,
      [responses.sendPort, libraryFile, config.toJson(), password],
      onError: responses.sendPort,
      onExit: responses.sendPort,
    );
    try {
      final values = await startup;
      final commands = values[0] as SendPort;
      final address = values[1] as int;
      return NativeStorageReader._(
        isolate,
        commands,
        responses,
        subscription,
        pending,
        library,
        address,
        workerExit,
      );
    } catch (_) {
      isolate.kill();
      await subscription.cancel();
      responses.close();
      rethrow;
    }
  }

  Future<Object?> _command(
    String operation,
    String path, [
    Object? arg1,
    Object? arg2,
  ]) {
    if (_closed || _closing || _workerExit.isCompleted) throw const FilmCatalogException('cancelled');
    validateFilmPath(path);
    final task = _tail.then((_) {
      if (_closing || _workerExit.isCompleted) throw const FilmCatalogException('cancelled');
      return _send(operation, path, arg1, arg2);
    });
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<Object?> _send(
    String operation,
    String path,
    Object? arg1,
    Object? arg2,
  ) {
    final id = ++_sequence;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send([id, operation, path, arg1, arg2]);
    return completer.future;
  }

  @override
  Future<List<Map<String, dynamic>>> list(String path) async =>
      (await _command('list', path) as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
  @override
  Future<Map<String, dynamic>> stat(String path) async =>
      Map<String, dynamic>.from(await _command('stat', path) as Map);
  @override
  Future<Uint8List> read(String path, int offset, int count) async {
    if (offset < 0 || count <= 0 || count > 1024 * 1024) {
      throw ArgumentError('Invalid storage read range');
    }
    return (await _command('read', path, offset, count)
            as TransferableTypedData)
        .materialize()
        .asUint8List();
  }

  @override
  Future<void> createFile(String path, Uint8List bytes) async {
    if (bytes.length > 16 * 1024 * 1024) {
      throw const FilmCatalogException('imageTooLarge');
    }
    await _command('create', path, TransferableTypedData.fromList([bytes]));
  }

  @override
  void cancelCurrent() {
    if (_closed || _closing || _workerExit.isCompleted) return;
    _library.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)
    >('sp_storage_cancel')(Pointer.fromAddress(_address));
  }

  @override
  Future<void> close() => _closeTask ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    cancelCurrent();
    _closing = true;
    try {
      await _tail;
      if (!_workerExit.isCompleted) await _send('close', '', null, null);
    } finally {
      _closed = true;
      await _subscription.cancel();
      _responses.close();
      _isolate.kill();
    }
  }

  static void _worker(List<Object> setup) {
    final output = setup[0] as SendPort;
    final library = DynamicLibrary.open(setup[1] as String);
    final config = MediaConnection.fromJson(
      Map<String, dynamic>.from(setup[2] as Map),
    );
    final input = ReceivePort();
    output.send(input.sendPort);
    final connect = library.lookupFunction<_ConnectNative, _Connect>(
      'sp_storage_connect',
    );
    final strings = [
      config.url,
      config.username,
      setup[3] as String,
      config.domain,
    ].map((value) => value.toNativeUtf8()).toList();
    late Pointer<Void> context;
    try {
      context = connect(
        switch (config.kind) {
          MediaSourceKind.smb => 0,
          MediaSourceKind.ftp => 1,
          MediaSourceKind.nfs => 2,
          _ => throw StateError('Invalid native protocol'),
        },
        strings[0],
        strings[1],
        strings[2],
        strings[3],
        config.nfsVersion,
        config.uid,
        config.gid,
        config.passive ? 1 : 0,
      );
    } finally {
      for (final value in strings) {
        calloc.free(value);
      }
    }
    if (context == nullptr) {
      output.send([0, false, 'sourceConnectionFailed']);
      input.close();
      return;
    }
    output.send([0, true, context.address]);
    final list = library.lookupFunction<_TextNative, _Text>('sp_storage_list');
    final stat = library.lookupFunction<_TextNative, _Text>('sp_storage_stat');
    final read = library.lookupFunction<_ReadNative, _Read>('sp_storage_read');
    final write = library.lookupFunction<_WriteNative, _Write>(
      'sp_storage_create_file',
    );
    final free = library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('sp_storage_free');
    final close = library
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('sp_storage_close');
    input.listen((raw) {
      final row = raw as List;
      final id = row[0] as int, operation = row[1] as String;
      final path = (row[2] as String).toNativeUtf8();
      try {
        Object? result;
        if (operation == 'close') {
          close(context);
          output.send([id, true, null]);
          input.close();
          return;
        }
        if (operation == 'list' || operation == 'stat') {
          final text = operation == 'list'
              ? list(context, path)
              : stat(context, path);
          try {
            result = jsonDecode(text.toDartString());
          } finally {
            free(text);
          }
          if (result is Map && result['error'] is int) {
            throw FilmCatalogException(
              nativeStorageError(result['error'] as int),
            );
          }
        } else if (operation == 'read') {
          final count = row[4] as int;
          final buffer = calloc<Uint8>(count);
          try {
            final size = read(context, path, row[3] as int, buffer, count);
            if (size < 0) throw FilmCatalogException(nativeStorageError(size));
            result = TransferableTypedData.fromList([buffer.asTypedList(size)]);
          } finally {
            calloc.free(buffer);
          }
        } else if (operation == 'create') {
          final bytes = (row[3] as TransferableTypedData)
              .materialize()
              .asUint8List();
          final buffer = calloc<Uint8>(bytes.length);
          try {
            buffer.asTypedList(bytes.length).setAll(0, bytes);
            final status = write(context, path, buffer, bytes.length);
            if (status < 0) {
              throw FilmCatalogException(nativeStorageError(status));
            }
          } finally {
            calloc.free(buffer);
          }
        } else {
          throw StateError('Unknown storage operation');
        }
        output.send([id, true, result]);
      } on FilmCatalogException catch (error) {
        output.send([id, false, error.code]);
      } on FormatException {
        output.send([id, false, 'sourceReadFailed']);
      } finally {
        calloc.free(path);
      }
    });
  }
}
